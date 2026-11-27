using Android.Content;
using Android.Graphics;
using Android.Media;
using Android.Views;
using System.Diagnostics;
using System.IO;

namespace PocketGB.Android;

/// <summary>Landscape Android play surface with touch controls and an independent emulation thread.</summary>
internal sealed class EmulatorSurfaceView : SurfaceView, ISurfaceHolderCallback, IDisposable
{
    private readonly object _coreLock = new();
    private readonly object _inputLock = new();
    private readonly string _filesDirectory;
    private readonly MgbaAndroidCore _core;
    private Thread? _loopThread;
    private volatile bool _stop;
    private bool _surfaceReady;
    private bool _lifecyclePaused;
    private bool _disposed;
    private bool _paused;
    private bool _turbo;
    private double _speed = 1.0;
    private static readonly double[] TurboSpeedOptions = { 2.0, 4.0, 6.0, 8.0, 12.0, 16.0 };
    private int _turboSpeedIndex = 1;
    private double _turboSpeed = 4.0;
    private uint _touchKeys;
    private uint _hardwareKeys;
    private int[] _bitmapPixels = Array.Empty<int>();
    private Bitmap? _bitmap;
    private readonly Paint _bitmapPaint = new() { FilterBitmap = false, AntiAlias = false };
    private readonly Paint _paint = new() { AntiAlias = true };
    private AudioTrack? _audioTrack;
    private short[] _audioBuffer = new short[4096];
    private double _renderFps;
    private double _gameFps;
    private int _framesInSample;
    private int _renderFramesInSample;
    private readonly Stopwatch _fpsWatch = Stopwatch.StartNew();
    private string _status = "Tap OPEN to choose a game";
    private string _gameTitle = "";

    public bool IsPaused { get { lock (_coreLock) return _paused; } }
    public bool TurboActive { get { lock (_coreLock) return _turbo; } }
    public double SpeedMultiplier { get { lock (_coreLock) return _speed; } }
    public double TurboSpeedMultiplier { get { lock (_coreLock) return _turboSpeed; } }

    public EmulatorSurfaceView(Context context, string filesDirectory) : base(context)
    {
        _filesDirectory = filesDirectory;
        _core = new MgbaAndroidCore();
        Holder.AddCallback(this);
        Focusable = true;
        FocusableInTouchMode = true;
        SetWillNotDraw(false);
    }

    public void LoadRom(string path)
    {
        lock (_coreLock)
        {
            _core.LoadRom(path);
            _gameTitle = _core.GameTitle;
            _status = $"{_core.PlatformName} • {_gameTitle}";
            _paused = false;
            EnsureAudioTrack(_core.AudioSampleRate);
            _core.CopyPixelsArgb(EnsurePixelBuffer(_core.Width * _core.Height));
        }
    }

    public void ApplyPatch(string path)
    {
        lock (_coreLock)
        {
            _core.ApplyPatchFile(path);
            _status = $"Patch applied • {_gameTitle}";
            _core.CopyPixelsArgb(EnsurePixelBuffer(_core.Width * _core.Height));
        }
    }

    public void TogglePause()
    {
        lock (_coreLock)
        {
            _paused = !_paused;
            _status = _paused ? "Paused" : $"{_core.PlatformName} • {_gameTitle}";
        }
    }

    public void CycleSpeed()
    {
        lock (_coreLock)
        {
            _speed = _speed < 0.99 ? 1.0 : _speed < 1.99 ? 2.0 : 0.5;
        }
    }

    public void ToggleTurbo()
    {
        lock (_coreLock)
        {
            _turbo = !_turbo;
            if (_turbo && _audioTrack != null)
            {
                // Remove queued normal-speed audio before fast-forward starts.
                try
                {
                    _audioTrack.Pause();
                    _audioTrack.Flush();
                    _audioTrack.Play();
                }
                catch { }
            }
        }
    }

    public double CycleTurboSpeed()
    {
        lock (_coreLock)
        {
            _turboSpeedIndex = (_turboSpeedIndex + 1) % TurboSpeedOptions.Length;
            _turboSpeed = TurboSpeedOptions[_turboSpeedIndex];
            return _turboSpeed;
        }
    }

    public void Reset()
    {
        lock (_coreLock)
        {
            _core.Reset();
            _status = "Game reset";
        }
    }

    public void SaveState()
    {
        lock (_coreLock)
        {
            if (!_core.HasRom) throw new InvalidOperationException("Open a game first.");
            _core.SaveState(_core.StatePath);
            _status = "Quick state saved";
        }
    }

    public void LoadState()
    {
        lock (_coreLock)
        {
            if (!_core.HasRom) throw new InvalidOperationException("Open a game first.");
            if (!_core.LoadState(_core.StatePath)) throw new FileNotFoundException("No quick-save state exists for this game yet.");
            _core.CopyPixelsArgb(EnsurePixelBuffer(_core.Width * _core.Height));
            _status = "Quick state loaded";
        }
    }

    public void PauseEmulation()
    {
        lock (_coreLock)
        {
            _lifecyclePaused = true;
            _core.SetKeys(0);
            if (_core.HasRom) _core.SaveBattery(_core.BatteryPath);
        }
        StopLoop();
    }

    public void ResumeEmulation()
    {
        lock (_coreLock) _lifecyclePaused = false;
        if (_surfaceReady) StartLoop();
    }

    public bool SetHardwareKey(Keycode key, bool down)
    {
        uint bit = key switch
        {
            Keycode.DpadUp => 1u << 6,
            Keycode.DpadDown => 1u << 7,
            Keycode.DpadLeft => 1u << 5,
            Keycode.DpadRight => 1u << 4,
            Keycode.Z or Keycode.ButtonA => 1u << 0,
            Keycode.X or Keycode.ButtonB => 1u << 1,
            Keycode.A or Keycode.ButtonL1 => 1u << 9,
            Keycode.S or Keycode.ButtonR1 => 1u << 8,
            Keycode.Enter or Keycode.ButtonStart => 1u << 3,
            Keycode.ButtonSelect => 1u << 2,
            _ => 0u
        };
        if (bit == 0) return false;
        lock (_inputLock)
        {
            if (down) _hardwareKeys |= bit;
            else _hardwareKeys &= ~bit;
        }
        return true;
    }

    public override bool OnTouchEvent(MotionEvent? e)
    {
        if (e == null) return false;
        uint keys = 0;
        MotionEventActions action = e.ActionMasked;
        int ignoreIndex = action is MotionEventActions.Up or MotionEventActions.PointerUp ? e.ActionIndex : -1;
        if (action != MotionEventActions.Cancel)
        {
            for (int i = 0; i < e.PointerCount; i++)
            {
                if (i == ignoreIndex) continue;
                keys |= KeysAt(e.GetX(i), e.GetY(i), Width, Height);
            }
        }
        lock (_inputLock) _touchKeys = keys;
        return true;
    }

    private static uint KeysAt(float x, float y, int width, int height)
    {
        if (width <= 0 || height <= 0) return 0;
        float w = width, h = height;
        uint keys = 0;

        // D-pad: independent axis zones allow diagonal movement.
        float dx = x - w * 0.19f;
        float dy = y - h * 0.80f;
        if (dx * dx + dy * dy < w * w * 0.17f * 0.17f)
        {
            if (Math.Abs(dx) > w * 0.035f) keys |= dx < 0 ? 1u << 5 : 1u << 4;
            if (Math.Abs(dy) > h * 0.04f) keys |= dy < 0 ? 1u << 6 : 1u << 7;
        }

        if (InsideCircle(x, y, w * 0.86f, h * 0.82f, w * 0.065f)) keys |= 1u << 0; // A
        if (InsideCircle(x, y, w * 0.72f, h * 0.90f, w * 0.060f)) keys |= 1u << 1; // B
        if (InsideCircle(x, y, w * 0.70f, h * 0.64f, w * 0.045f)) keys |= 1u << 9; // L
        if (InsideCircle(x, y, w * 0.89f, h * 0.64f, w * 0.045f)) keys |= 1u << 8; // R
        if (InsideCircle(x, y, w * 0.49f, h * 0.91f, w * 0.045f)) keys |= 1u << 2; // Select
        if (InsideCircle(x, y, w * 0.60f, h * 0.91f, w * 0.045f)) keys |= 1u << 3; // Start
        return keys;
    }

    private static bool InsideCircle(float x, float y, float cx, float cy, float radius)
    {
        float dx = x - cx, dy = y - cy;
        return dx * dx + dy * dy <= radius * radius;
    }

    public void SurfaceCreated(ISurfaceHolder holder)
    {
        _surfaceReady = true;
        if (!_lifecyclePaused) StartLoop();
    }

    public void SurfaceChanged(ISurfaceHolder holder, Format format, int width, int height) { }

    public void SurfaceDestroyed(ISurfaceHolder holder)
    {
        _surfaceReady = false;
        StopLoop();
    }

    private void StartLoop()
    {
        if (_disposed || !_surfaceReady || _lifecyclePaused) return;
        if (_loopThread is { IsAlive: true }) return;
        _stop = false;
        _loopThread = new Thread(GameLoop) { IsBackground = true, Name = "PocketGB Android emulation" };
        _loopThread.Start();
    }

    private void StopLoop()
    {
        _stop = true;
        Thread? old = _loopThread;
        if (old != null && old != Thread.CurrentThread) old.Join(1000);
        _loopThread = null;
    }

    private void GameLoop()
    {
        var gameFpsTimer = Stopwatch.StartNew();
        long last = Stopwatch.GetTimestamp();
        var framePacer = new EmulationFramePacer(maxFramesPerBatch: 32, maxBacklogFrames: 32);
        int turboRenderCounter = 0;
        _ = EnsurePixelBuffer(256 * 224);

        while (!_stop)
        {
            long now = Stopwatch.GetTimestamp();
            double delta = Math.Clamp((now - last) / (double)Stopwatch.Frequency, 0, 0.1);
            last = now;
            int framesToRun = 0;
            double fps = 59.7275;
            bool turboActive = false;
            double turboMultiplier = 4.0;
            uint keys;
            lock (_inputLock) keys = _touchKeys | _hardwareKeys;

            lock (_coreLock)
            {
                _core.SetKeys(keys);
                if (_core.HasRom && !_paused)
                {
                    turboActive = _turbo;
                    turboMultiplier = _turboSpeed;
                    double multiplier = turboActive ? turboMultiplier : _speed;
                    framesToRun = framePacer.Consume(delta, multiplier, _core.FrameRate);
                    fps = _core.FrameRate;
                    for (int i = 0; i < framesToRun; i++)
                    {
                        _core.RunFrame();
                        _framesInSample++;
                    }
                    if (framesToRun > 0) _core.CopyPixelsArgb(EnsurePixelBuffer(_core.Width * _core.Height));
                    // AudioTrack.Write is blocking. Drain mGBA's queue, but do not write during
                    // turbo, otherwise audio playback limits the emulation speed.
                    PumpAudio(discardOutput: turboActive);
                }
                else
                {
                    framePacer.Reset();
                    PumpAudio(discardOutput: true);
                }

                if (gameFpsTimer.Elapsed.TotalSeconds >= 0.5)
                {
                    _gameFps = _framesInSample / Math.Max(0.001, gameFpsTimer.Elapsed.TotalSeconds);
                    _framesInSample = 0;
                    gameFpsTimer.Restart();
                }
            }

            int renderInterval = turboActive ? (turboMultiplier >= 8.0 ? 3 : 2) : 1;
            bool renderNow = !turboActive || (++turboRenderCounter % renderInterval == 0);
            if (renderNow) RenderFrame();

            long usedTicks = Stopwatch.GetTimestamp() - now;
            if (turboActive)
            {
                // Yield briefly instead of sleeping at 60 Hz; render less often to prioritize emulation.
                Thread.Yield();
            }
            else
            {
                double remainingMs = (1000.0 / 60.0) - usedTicks * 1000.0 / Stopwatch.Frequency;
                if (remainingMs > 1) Thread.Sleep(Math.Max(1, (int)remainingMs));
                else if (remainingMs > 0) Thread.SpinWait(20);
            }
        }
    }

    private int[] EnsurePixelBuffer(int required)
    {
        if (_bitmapPixels.Length < required) _bitmapPixels = new int[required];
        return _bitmapPixels;
    }

    private void EnsureAudioTrack(int sampleRate)
    {
        try
        {
            _audioTrack?.Stop();
            _audioTrack?.Release();
            int rate = sampleRate > 8000 && sampleRate <= 96000 ? sampleRate : 48000;
            int bufferBytes = AudioTrack.GetMinBufferSize(rate, ChannelOut.Stereo, Encoding.Pcm16bit);
            bufferBytes = Math.Max(bufferBytes, rate / 5 * 4);
            _audioTrack = new AudioTrack(global::Android.Media.Stream.Music, rate, ChannelConfiguration.Stereo,
                Encoding.Pcm16bit, bufferBytes, AudioTrackMode.Stream);
            if (_audioTrack.State == AudioTrackState.Initialized) _audioTrack.Play();
        }
        catch
        {
            _audioTrack?.Release();
            _audioTrack = null;
            _status = "Audio output unavailable; running silently";
        }
    }

    private void PumpAudio(bool discardOutput = false)
    {
        // Always drain the native queue, even while muted or when AudioTrack is unavailable.
        int available = _core.AudioAvailable;
        if (available <= 0) return;
        int sampleCount = available * 2;
        if (_audioBuffer.Length < sampleCount) _audioBuffer = new short[sampleCount];
        int read = _core.ReadAudio(_audioBuffer, available);
        if (read > 0 && !discardOutput && _audioTrack != null)
        {
            try { _audioTrack.Write(_audioBuffer, 0, read * 2); }
            catch { _audioTrack?.Pause(); }
        }
    }

    private void RenderFrame()
    {
        if (!_surfaceReady || _disposed) return;
        global::Android.Graphics.Canvas? canvas = null;
        try
        {
            canvas = Holder.LockCanvas();
            if (canvas == null) return;

            _renderFramesInSample++;
            if (_fpsWatch.Elapsed.TotalSeconds >= 0.5)
            {
                _renderFps = _renderFramesInSample / Math.Max(0.001, _fpsWatch.Elapsed.TotalSeconds);
                _renderFramesInSample = 0;
                _fpsWatch.Restart();
            }

            canvas.DrawColor(Color.Rgb(14, 19, 17));

            lock (_coreLock)
            {
                if (_core.HasRom && _bitmapPixels.Length >= _core.Width * _core.Height)
                {
                    if (_bitmap == null || _bitmap.Width != _core.Width || _bitmap.Height != _core.Height)
                    {
                        _bitmap?.Recycle();
                        _bitmap = Bitmap.CreateBitmap(_core.Width, _core.Height, Bitmap.Config.Argb8888);
                    }
                    _bitmap!.SetPixels(_bitmapPixels, 0, _core.Width, 0, 0, _core.Width, _core.Height);
                    float areaTop = canvas.Height * 0.14f;
                    float areaBottom = canvas.Height * 0.94f;
                    float scale = Math.Min(canvas.Width / (float)_core.Width,
                        (areaBottom - areaTop) / _core.Height);
                    float imageWidth = _core.Width * scale;
                    float imageHeight = _core.Height * scale;
                    float left = (canvas.Width - imageWidth) / 2f;
                    float top = areaTop + ((areaBottom - areaTop) - imageHeight) / 2f;
                    canvas.DrawBitmap(_bitmap, null,
                        new RectF(left, top, left + imageWidth, top + imageHeight), _bitmapPaint);
                }
                DrawTouchOverlay(canvas);
                DrawStatus(canvas);
            }
        }
        catch (Exception ex)
        {
            _status = ex.Message;
        }
        finally
        {
            if (canvas != null)
            {
                try { Holder.UnlockCanvasAndPost(canvas); }
                catch { }
            }
        }
    }

    private void DrawTouchOverlay(global::Android.Graphics.Canvas canvas)
    {
        float w = canvas.Width, h = canvas.Height;
        uint touch;
        lock (_inputLock) touch = _touchKeys | _hardwareKeys;

        _paint.SetStyle(Paint.Style.Fill);
        _paint.Color = Color.Argb(120, 205, 225, 214);
        // D-pad cross.
        canvas.DrawRoundRect(new RectF(w * 0.145f, h * 0.685f, w * 0.235f, h * 0.915f), 12, 12, _paint);
        canvas.DrawRoundRect(new RectF(w * 0.075f, h * 0.755f, w * 0.305f, h * 0.845f), 12, 12, _paint);
        _paint.Color = Color.Argb(210, 25, 55, 43);
        canvas.DrawText("▲", w * 0.167f, h * 0.735f, TextPaint(32));
        canvas.DrawText("▼", w * 0.167f, h * 0.895f, TextPaint(32));
        canvas.DrawText("◀", w * 0.085f, h * 0.825f, TextPaint(32));
        canvas.DrawText("▶", w * 0.255f, h * 0.825f, TextPaint(32));

        DrawTouchButton(canvas, w * 0.86f, h * 0.82f, w * 0.065f, "A", (touch & 1u) != 0);
        DrawTouchButton(canvas, w * 0.72f, h * 0.90f, w * 0.060f, "B", (touch & 2u) != 0);
        DrawTouchButton(canvas, w * 0.70f, h * 0.64f, w * 0.045f, "L", (touch & (1u << 9)) != 0);
        DrawTouchButton(canvas, w * 0.89f, h * 0.64f, w * 0.045f, "R", (touch & (1u << 8)) != 0);
        DrawTouchButton(canvas, w * 0.49f, h * 0.91f, w * 0.045f, "SEL", (touch & (1u << 2)) != 0);
        DrawTouchButton(canvas, w * 0.60f, h * 0.91f, w * 0.045f, "START", (touch & (1u << 3)) != 0);
    }

    private Paint TextPaint(float size)
    {
        _paint.TextSize = size;
        _paint.SetTypeface(Typeface.Create("sans-serif-medium", TypefaceStyle.Bold));
        _paint.TextAlign = Paint.Align.Center;
        return _paint;
    }

    private void DrawTouchButton(global::Android.Graphics.Canvas canvas, float cx, float cy, float radius, string label, bool pressed)
    {
        _paint.SetStyle(Paint.Style.Fill);
        _paint.Color = pressed ? Color.Argb(220, 125, 210, 163) : Color.Argb(135, 225, 235, 229);
        canvas.DrawCircle(cx, cy, radius, _paint);
        _paint.Color = Color.Argb(230, 15, 34, 27);
        _paint.TextSize = label.Length > 3 ? radius * 0.45f : radius * 0.85f;
        _paint.SetTypeface(Typeface.Create("sans-serif-medium", TypefaceStyle.Bold));
        _paint.TextAlign = Paint.Align.Center;
        canvas.DrawText(label, cx, cy + _paint.TextSize * 0.34f, _paint);
    }

    private void DrawStatus(global::Android.Graphics.Canvas canvas)
    {
        _paint.Color = Color.Argb(215, 220, 240, 228);
        _paint.TextSize = Math.Max(14, canvas.Height * 0.025f);
        _paint.SetTypeface(Typeface.Create("sans-serif-medium", TypefaceStyle.Normal));
        _paint.TextAlign = Paint.Align.Left;
        string title = string.IsNullOrWhiteSpace(_gameTitle) ? _status : _gameTitle;
        canvas.DrawText(title, canvas.Width * 0.025f, canvas.Height * 0.17f, _paint);
        _paint.TextAlign = Paint.Align.Right;
        string mode = _turbo ? $"FAST {_turboSpeed:0.#}x" : $"SPEED {_speed:0.##}x";
        canvas.DrawText($"GAME {_gameFps:0.0} FPS  •  RENDER {_renderFps:0}  •  {mode}",
            canvas.Width * 0.975f, canvas.Height * 0.17f, _paint);
        if (!string.IsNullOrWhiteSpace(_status) && !_core.HasRom)
        {
            _paint.TextAlign = Paint.Align.Center;
            _paint.TextSize = Math.Max(18, canvas.Height * 0.035f);
            canvas.DrawText(_status, canvas.Width * 0.5f, canvas.Height * 0.48f, _paint);
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        StopLoop();
        lock (_coreLock)
        {
            try
            {
                if (_core.HasRom) _core.SaveBattery(_core.BatteryPath);
            }
            catch { }
            _core.Dispose();
            _audioTrack?.Stop();
            _audioTrack?.Release();
            _audioTrack = null;
            _bitmap?.Recycle();
            _bitmap = null;
        }
        Holder.RemoveCallback(this);
    }
}
