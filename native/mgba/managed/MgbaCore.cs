using System.Collections.Generic;
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Serilog;
using PocketGB.Shared;

namespace GameboySharp;

/// <summary>
/// Managed owner for the optional native mGBA core. The native DLL is only built
/// for Windows x64 at present; the existing GameboySharp GB/GBC core remains usable
/// on platforms where the DLL is not installed.
/// </summary>
internal sealed unsafe class MgbaCore : IDisposable
{
    private const string NativeLibraryName = "pocketgb-mgba";
    private const int MaxAudioFrames = 16384;


    static MgbaCore()
    {
        System.Runtime.InteropServices.NativeLibrary.SetDllImportResolver(
            typeof(MgbaCore).Assembly, ResolveNativeLibrary);
    }

    private static IntPtr ResolveNativeLibrary(
        string libraryName, System.Reflection.Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (!string.Equals(libraryName, NativeLibraryName, StringComparison.OrdinalIgnoreCase))
            return IntPtr.Zero;

        var candidates = new List<string>();
        string? explicitPath = Environment.GetEnvironmentVariable("PGB_MGBA_NATIVE_DLL");
        if (!string.IsNullOrWhiteSpace(explicitPath))
            candidates.Add(Path.GetFullPath(explicitPath));

        string fileName = NativeLibraryName + (OperatingSystem.IsWindows() ? ".dll" :
            OperatingSystem.IsMacOS() ? ".dylib" : ".so");
        string baseDirectory = AppContext.BaseDirectory;
        candidates.Add(Path.Combine(baseDirectory, fileName));
        candidates.Add(Path.Combine(baseDirectory, "runtimes", "win-x64", "native", fileName));
        candidates.Add(Path.Combine(Environment.CurrentDirectory, "artifacts", "native", "win-x64", fileName));

        foreach (string candidate in candidates)
        {
            if (File.Exists(candidate) &&
                System.Runtime.InteropServices.NativeLibrary.TryLoad(candidate, out IntPtr handle))
                return handle;
        }

        // Let the platform default loader try its normal search paths as a final fallback.
        return IntPtr.Zero;
    }

    private readonly EmulatorConfig _config;
    private IntPtr _context;
    private IAudioSink? _audioSink;
    private string? _sourcePath;
    private string? _resolvedRomPath;
    private string? _batterySavePath;
    private string? _saveStatePath;
    private uint[] _frameBuffer = Array.Empty<uint>();
    private short[] _nativeAudio = new short[MaxAudioFrames * 2];
    private short[] _resampleInput = Array.Empty<short>();
    private short[] _outputLeft = new short[4096];
    private short[] _outputRight = new short[4096];
    private double _sourcePosition = 1.0;
    private int _lastSourceRate;
    private short _previousLeft;
    private short _previousRight;
    private bool _hasPreviousSample;
    private int _framesSinceBatterySave;
    private bool _disposed;

    public bool HasRom { get; private set; }
    public string GameTitle { get; private set; } = "(no game)";
    public string GameCode { get; private set; } = "";
    public string PlatformName { get; private set; } = "mGBA";
    public int FrameWidth { get; private set; } = 160;
    public int FrameHeight { get; private set; } = 144;
    public double NominalFrameRate { get; private set; } = 59.7275;
    public uint[] FrameBuffer => _frameBuffer;
    public bool Muted { get; set; }
    public bool IsPaused { get; set; }
    public int FramesPerSecond => (int)Math.Round(NominalFrameRate);

    public MgbaCore(EmulatorConfig config)
    {
        _config = config ?? throw new ArgumentNullException(nameof(config));

        _context = pgb_mgba_create();
        if (_context == IntPtr.Zero)
            throw new InvalidOperationException("The native mGBA core could not allocate its context.");

        // Reuse PocketGB's configured audio output. If audio is unavailable, emulation remains usable.
        if (!string.Equals(Environment.GetEnvironmentVariable("GBSHARP_AUDIO"), "none", StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                _audioSink = Emulator.CreateAudioSink(config.Audio.Backend);
            }
            catch (Exception ex)
            {
                Log.Warning(ex, "mGBA audio output could not be initialized. The game will run silently.");
                _audioSink = null;
            }
        }
    }

    public void LoadRom(string sourcePath)
    {
        ThrowIfDisposed();
        if (HasRom) SaveBattery();
        HasRom = false;
        GameTitle = "(loading)";
        string cacheRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PocketGB", "rom-cache");
        if (string.IsNullOrWhiteSpace(cacheRoot) || cacheRoot == Path.DirectorySeparatorChar.ToString())
            cacheRoot = Path.Combine(Path.GetTempPath(), "PocketGB", "rom-cache");

        string resolvedPath = CartridgeFileLoader.ResolveRomPath(sourcePath, cacheRoot);
        int loaded;
        if (CartridgeFileLoader.IsSevenZipArchive(resolvedPath))
        {
            loaded = pgb_mgba_load_7z_file(_context, resolvedPath);
        }
        else
        {
            byte[] rom = File.ReadAllBytes(resolvedPath);
            if (rom.Length == 0 || rom.Length > CartridgeFileLoader.MaxRomBytes)
                throw new InvalidDataException("ROM size must be between 1 byte and 32 MiB.");
            unsafe
            {
                fixed (byte* pointer = rom)
                    loaded = pgb_mgba_load_rom(_context, pointer, (nuint)rom.Length);
            }
        }

        if (loaded == 0)
            throw new InvalidDataException(GetLastError());

        _sourcePath = Path.GetFullPath(sourcePath);
        _resolvedRomPath = Path.GetFullPath(resolvedPath);

        // Apply standard mGBA sidecar patches automatically. An invalid patch is reported,
        // but the unpatched cartridge remains loaded so users can still launch the game.
        try
        {
            string? patchPath = CartridgeFileLoader.FindSidecarPatch(_sourcePath, _resolvedRomPath);
            if (patchPath != null)
            {
                byte[] patch = File.ReadAllBytes(patchPath);
                unsafe
                {
                    fixed (byte* pointer = patch)
                    {
                        if (pgb_mgba_apply_patch(_context, pointer, (nuint)patch.Length) == 0)
                            Log.Warning("Could not apply sidecar patch {Patch}: {Reason}", patchPath, GetLastError());
                        else
                            Log.Information("Applied mGBA sidecar patch {Patch}", patchPath);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warning(ex, "Could not apply a sidecar patch for {Rom}; loading the unpatched game.", sourcePath);
        }

        _batterySavePath = ResolveSavePath(".sav");
        _saveStatePath = ResolveSavePath(".state0");

        FrameWidth = pgb_mgba_video_width(_context);
        FrameHeight = pgb_mgba_video_height(_context);
        EnsureFrameBuffer();
        GameTitle = GetNativeText(pgb_mgba_game_title);
        GameCode = GetNativeText(pgb_mgba_game_code);
        int platform = pgb_mgba_platform(_context);
        PlatformName = platform == 0 ? "Game Boy Advance" : platform == 1 ? "Game Boy / Color" : "mGBA";
        double frameRate = pgb_mgba_frame_rate(_context);
        if (double.IsFinite(frameRate) && frameRate > 1.0 && frameRate < 240.0)
            NominalFrameRate = frameRate;

        _sourcePosition = 1.0;
        _hasPreviousSample = false;
        _lastSourceRate = pgb_mgba_audio_sample_rate(_context);
        _framesSinceBatterySave = 0;
        HasRom = true;

        LoadBatterySave();
        Log.Information("Loaded {Platform} game {Title} ({Code}), {Width}x{Height} @ {FrameRate:0.000} Hz",
            PlatformName, GameTitle, GameCode, FrameWidth, FrameHeight, NominalFrameRate);
    }

    public void RunFrames(int frameCount)
    {
        ThrowIfDisposed();
        if (frameCount < 0 || frameCount > EmulationFramePacer.MaxFramesPerBatch)
            throw new ArgumentOutOfRangeException(nameof(frameCount));
        if (!HasRom || IsPaused || frameCount == 0)
        {
            PumpAudio();
            return;
        }

        for (int i = 0; i < frameCount; i++)
        {
            if (pgb_mgba_run_frame(_context) == 0)
                throw new InvalidOperationException(GetLastError());

            FrameWidth = pgb_mgba_video_width(_context);
            FrameHeight = pgb_mgba_video_height(_context);
            EnsureFrameBuffer();
            CopyVideoFrame();
            _framesSinceBatterySave++;
        }

        PumpAudio();
        if (_framesSinceBatterySave >= 600)
            SaveBattery();
    }

    public void SetKeys(uint keys)
    {
        if (_context != IntPtr.Zero && HasRom)
            pgb_mgba_set_keys(_context, keys);
    }

    public void Reset()
    {
        ThrowIfDisposed();
        if (!HasRom) return;
        pgb_mgba_reset(_context);
        FrameWidth = pgb_mgba_video_width(_context);
        FrameHeight = pgb_mgba_video_height(_context);
        EnsureFrameBuffer();
        _sourcePosition = 1.0;
        _hasPreviousSample = false;
    }

    public void SaveState()
    {
        ThrowIfDisposed();
        if (!HasRom || string.IsNullOrWhiteSpace(_saveStatePath)) return;

        nuint size = pgb_mgba_state_size(_context);
        if (size == 0 || size > (nuint)(64 * 1024 * 1024))
            throw new InvalidOperationException("mGBA returned an invalid save-state size.");

        byte[] state = new byte[(int)size];
        unsafe
        {
            fixed (byte* destination = state)
            {
                if (pgb_mgba_save_state(_context, destination, size) == 0)
                    throw new IOException("mGBA could not serialize the current save state.");
            }
        }

        string temporary = _saveStatePath + ".tmp";
        File.WriteAllBytes(temporary, state);
        File.Move(temporary, _saveStatePath, true);
    }

    public bool LoadState()
    {
        ThrowIfDisposed();
        if (!HasRom || string.IsNullOrWhiteSpace(_saveStatePath) || !File.Exists(_saveStatePath))
            return false;

        byte[] state = File.ReadAllBytes(_saveStatePath);
        unsafe
        {
            fixed (byte* source = state)
            {
                if (pgb_mgba_load_state(_context, source, (nuint)state.Length) == 0)
                    return false;
            }
        }

        FrameWidth = pgb_mgba_video_width(_context);
        FrameHeight = pgb_mgba_video_height(_context);
        EnsureFrameBuffer();
        CopyVideoFrame();
        return true;
    }

    public void SaveBattery()
    {
        if (_context == IntPtr.Zero || !HasRom || string.IsNullOrWhiteSpace(_batterySavePath))
            return;

        nuint size = pgb_mgba_savedata_size(_context);
        if (size == 0 || size > (nuint)(16 * 1024 * 1024))
        {
            _framesSinceBatterySave = 0;
            return;
        }

        byte[] data = new byte[(int)size];
        unsafe
        {
            fixed (byte* destination = data)
            {
                nuint copied = pgb_mgba_savedata_copy(_context, destination, size);
                if (copied != size)
                    throw new IOException("mGBA could not copy the cartridge battery-save data.");
            }
        }

        Directory.CreateDirectory(Path.GetDirectoryName(_batterySavePath)!);
        string temporary = _batterySavePath + ".tmp";
        File.WriteAllBytes(temporary, data);
        File.Move(temporary, _batterySavePath, true);
        _framesSinceBatterySave = 0;
    }

    private void LoadBatterySave()
    {
        if (string.IsNullOrWhiteSpace(_batterySavePath) || !File.Exists(_batterySavePath))
            return;

        try
        {
            byte[] data = File.ReadAllBytes(_batterySavePath);
            if (data.Length == 0 || data.Length > 16 * 1024 * 1024)
            {
                QuarantineBatterySave("empty or exceeds the 16 MiB safety limit");
                return;
            }

            unsafe
            {
                fixed (byte* source = data)
                {
                    if (pgb_mgba_savedata_load(_context, source, (nuint)data.Length) == 0)
                    {
                        QuarantineBatterySave("rejected by the active cartridge core");
                        return;
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warning(ex, "Could not load the existing battery save for {Game}; the cartridge will start with fresh save data.", GameTitle);
        }
    }

    private void QuarantineBatterySave(string reason)
    {
        if (string.IsNullOrWhiteSpace(_batterySavePath) || !File.Exists(_batterySavePath)) return;
        string backup = _batterySavePath + ".corrupt-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmssfff");
        try
        {
            File.Move(_batterySavePath, backup);
            Log.Warning("Preserved an unreadable battery save at {Backup} ({Reason}). Starting with fresh save data.", backup, reason);
        }
        catch (Exception ex)
        {
            Log.Warning(ex, "Could not quarantine the unreadable battery save at {Path}.", _batterySavePath);
        }
    }

    private string ResolveSavePath(string extension)
    {
        string source = _sourcePath ?? _resolvedRomPath ?? throw new InvalidOperationException("No ROM has been loaded.");
        string? configuredDirectory = _config.General.SaveDirectory;
        if (!string.IsNullOrWhiteSpace(configuredDirectory))
        {
            string directory = Path.GetFullPath(configuredDirectory);
            Directory.CreateDirectory(directory);
            return Path.Combine(directory, Path.GetFileNameWithoutExtension(source) + extension);
        }

        return Path.ChangeExtension(source, extension);
    }

    private void EnsureFrameBuffer()
    {
        if (FrameWidth <= 0 || FrameHeight <= 0 || FrameWidth > 256 || FrameHeight > 224)
            throw new InvalidDataException($"mGBA returned an unsupported video size: {FrameWidth}x{FrameHeight}.");

        int required = checked(FrameWidth * FrameHeight);
        if (_frameBuffer.Length != required)
            _frameBuffer = new uint[required];
    }

    private void CopyVideoFrame()
    {
        IntPtr pixels = pgb_mgba_video_pixels(_context);
        if (pixels == IntPtr.Zero) throw new InvalidOperationException("mGBA returned an empty video buffer.");
        fixed (uint* destination = _frameBuffer)
        {
            long byteCount = (long)_frameBuffer.Length * sizeof(uint);
            Buffer.MemoryCopy(pixels.ToPointer(), destination, byteCount, byteCount);
        }
    }

    private string GetNativeText(NativeTextGetter getter)
    {
        var builder = new StringBuilder(64);
        getter(_context, builder, (nuint)builder.Capacity);
        return builder.ToString().TrimEnd('\0', ' ');
    }

    private delegate void NativeTextGetter(IntPtr context, StringBuilder destination, nuint capacity);

    private string GetLastError()
    {
        IntPtr error = pgb_mgba_last_error(_context);
        return error == IntPtr.Zero
            ? "mGBA rejected the selected ROM."
            : Marshal.PtrToStringUTF8(error) ?? "mGBA rejected the selected ROM.";
    }

    private void PumpAudio()
    {
        if (_audioSink == null || _context == IntPtr.Zero || !HasRom)
            return;

        int available = Math.Clamp(pgb_mgba_audio_available(_context), 0, MaxAudioFrames);
        if (available > 0)
        {
            int needed = available * 2;
            if (_nativeAudio.Length < needed)
                Array.Resize(ref _nativeAudio, needed);

            int read;
            unsafe
            {
                fixed (short* destination = _nativeAudio)
                    read = pgb_mgba_audio_read(_context, destination, available);
            }

            if (read > 0 && !Muted && !_config.Audio.Muted)
                ResampleAndSubmit(read, pgb_mgba_audio_sample_rate(_context));
        }

        _audioSink.Update();
    }

    private void ResampleAndSubmit(int sourceFrames, int sourceRate)
    {
        if (sourceRate <= 0 || _audioSink == null || sourceFrames <= 0)
            return;

        int destinationRate = _audioSink.SampleRate;
        if (destinationRate <= 0) return;

        if (_lastSourceRate != sourceRate)
        {
            _lastSourceRate = sourceRate;
            _sourcePosition = 1.0;
            _hasPreviousSample = false;
        }

        int combinedFrames = sourceFrames + 1;
        int requiredSamples = combinedFrames * 2;
        if (_resampleInput.Length < requiredSamples)
            Array.Resize(ref _resampleInput, requiredSamples);

        short firstLeft = _nativeAudio[0];
        short firstRight = _nativeAudio[1];
        if (_hasPreviousSample)
        {
            _resampleInput[0] = _previousLeft;
            _resampleInput[1] = _previousRight;
        }
        else
        {
            _resampleInput[0] = firstLeft;
            _resampleInput[1] = firstRight;
            _sourcePosition = 1.0;
        }

        Array.Copy(_nativeAudio, 0, _resampleInput, 2, sourceFrames * 2);

        double step = (double)sourceRate / destinationRate;
        double position = _sourcePosition;
        int outputFrames = 0;

        int estimated = (int)Math.Ceiling((sourceFrames + 1) * (double)destinationRate / sourceRate) + 4;
        EnsureOutputBuffers(Math.Max(estimated, 16));

        while (position + 1.0 < combinedFrames && outputFrames < _outputLeft.Length)
        {
            int index = (int)position;
            double fraction = position - index;
            int sourceIndex = index * 2;
            int nextIndex = sourceIndex + 2;

            double left = _resampleInput[sourceIndex] +
                (_resampleInput[nextIndex] - _resampleInput[sourceIndex]) * fraction;
            double right = _resampleInput[sourceIndex + 1] +
                (_resampleInput[nextIndex + 1] - _resampleInput[sourceIndex + 1]) * fraction;

            _outputLeft[outputFrames] = (short)Math.Clamp((int)Math.Round(left), short.MinValue, short.MaxValue);
            _outputRight[outputFrames] = (short)Math.Clamp((int)Math.Round(right), short.MinValue, short.MaxValue);
            outputFrames++;
            position += step;
        }

        _sourcePosition = position - sourceFrames;
        _previousLeft = _nativeAudio[(sourceFrames - 1) * 2];
        _previousRight = _nativeAudio[(sourceFrames - 1) * 2 + 1];
        _hasPreviousSample = true;

        if (outputFrames > 0)
        {
            if (_audioSink is IAudioSinkWithCount lengthAware)
                lengthAware.Submit(_outputLeft, _outputRight, outputFrames);
            else
            {
                // Fallback for a non-PocketGB audio sink that has not implemented the length-aware path.
                short[] left = _outputLeft.AsSpan(0, outputFrames).ToArray();
                short[] right = _outputRight.AsSpan(0, outputFrames).ToArray();
                _audioSink.Submit(left, right);
            }
        }
    }

    private void EnsureOutputBuffers(int required)
    {
        if (_outputLeft.Length >= required) return;
        int size = Math.Min(32768, Math.Max(required, _outputLeft.Length * 2));
        Array.Resize(ref _outputLeft, size);
        Array.Resize(ref _outputRight, size);
    }

    private void ThrowIfDisposed()
    {
        if (_disposed) throw new ObjectDisposedException(nameof(MgbaCore));
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        try { SaveBattery(); }
        catch (Exception ex) { Log.Warning(ex, "Could not save mGBA cartridge data during shutdown."); }

        if (_context != IntPtr.Zero)
        {
            pgb_mgba_destroy(_context);
            _context = IntPtr.Zero;
        }

        _audioSink?.Dispose();
        _audioSink = null;
    }

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int pgb_mgba_load_7z_file(IntPtr context, [MarshalAs(UnmanagedType.LPUTF8Str)] string path);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int pgb_mgba_apply_patch(IntPtr context, byte* patch, nuint patchBytes);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr pgb_mgba_create();

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern void pgb_mgba_destroy(IntPtr context);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr pgb_mgba_last_error(IntPtr context);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int pgb_mgba_load_rom(IntPtr context, byte* rom, nuint romBytes);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int pgb_mgba_run_frame(IntPtr context);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr pgb_mgba_video_pixels(IntPtr context);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int pgb_mgba_video_width(IntPtr context);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int pgb_mgba_video_height(IntPtr context);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int pgb_mgba_platform(IntPtr context);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern void pgb_mgba_game_title(IntPtr context, StringBuilder destination, nuint capacity);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern void pgb_mgba_game_code(IntPtr context, StringBuilder destination, nuint capacity);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern double pgb_mgba_frame_rate(IntPtr context);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern void pgb_mgba_set_keys(IntPtr context, uint keys);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int pgb_mgba_audio_sample_rate(IntPtr context);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int pgb_mgba_audio_available(IntPtr context);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int pgb_mgba_audio_read(IntPtr context, short* destination, int frames);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern nuint pgb_mgba_state_size(IntPtr context);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int pgb_mgba_save_state(IntPtr context, byte* destination, nuint capacity);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int pgb_mgba_load_state(IntPtr context, byte* source, nuint size);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern nuint pgb_mgba_savedata_size(IntPtr context);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern nuint pgb_mgba_savedata_copy(IntPtr context, byte* destination, nuint capacity);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern int pgb_mgba_savedata_load(IntPtr context, byte* source, nuint size);

    [DllImport(NativeLibraryName, CallingConvention = CallingConvention.Cdecl)]
    private static extern void pgb_mgba_reset(IntPtr context);
}
