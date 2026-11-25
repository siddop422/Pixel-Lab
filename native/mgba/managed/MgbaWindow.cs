using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Numerics;
using ImGuiNET;
using Serilog;
using Silk.NET.Input;
using Silk.NET.Maths;
using Silk.NET.OpenGL;
using Silk.NET.OpenGL.Extensions.ImGui;
using Silk.NET.Windowing;

namespace GameboySharp;

/// <summary>
/// A compact multi-system host for the optional mGBA core. It deliberately lives
/// beside the original GameboySharp window so the existing GB/GBC debugger path
/// stays unchanged while mGBA can present GBA's different 240x160 framebuffer.
/// </summary>
internal sealed class MgbaWindow : IDisposable
{
    private readonly IWindow _window;
    private readonly IInputContext _input;
    private readonly GL _gl;
    private readonly ImGuiController _imgui;
    private readonly MgbaCore _core;
    private readonly MgbaFrameRenderer _renderer;
    private readonly FileBrowser _fileBrowser;
    private readonly EmulatorConfig _config;
    private readonly Action? _returnToGameboySharp;
    private readonly Dictionary<Key, bool> _previousKeys = new();

    private bool _disposed;
    private bool _suppressReturn;
    private bool _turboActive;
    private double _renderFps;
    private double _gameFps;
    private int _gameFramesInSample;
    private int _titleRefresh;
    private readonly Stopwatch _gameFpsTimer = Stopwatch.StartNew();
    private string _lastError = "";

    public IWindow SilkWindow => _window;
    public bool HasRom => _core.HasRom;
    public bool IsPaused => _core.IsPaused;
    public bool TurboActive => _turboActive;
    public double NominalFrameRate => _core.NominalFrameRate;
    public bool IsClosing => _window.IsClosing;

    public MgbaWindow(EmulatorConfig config, Action? returnToGameboySharp = null)
    {
        _config = config ?? throw new ArgumentNullException(nameof(config));
        _returnToGameboySharp = returnToGameboySharp;

        var options = WindowOptions.Default;
        options.API = new GraphicsAPI(ContextAPI.OpenGL, new APIVersion(3, 3));
        options.Title = "PocketGB — mGBA";
        options.Size = new Vector2D<int>(Math.Max(960, config.WindowWidth), Math.Max(640, config.WindowHeight));
        options.VSync = config.Video.VSync;

        _window = Window.Create(options);
        _window.Initialize();
        _gl = _window.CreateOpenGL();
        _input = _window.CreateInput();
        _imgui = new ImGuiController(_gl, _window, _input);
        _renderer = new MgbaFrameRenderer(_gl, config.Video.UpscaleMode != VideoUpscaleMode.PixelPerfect);
        _core = new MgbaCore(config);

        string? startDirectory = config.RecentRoms.Count > 0
            ? Path.GetDirectoryName(config.RecentRoms[0])
            : null;
        _fileBrowser = new FileBrowser(startDirectory);
        _fileBrowser.OnRomChosen = LoadRom;

        _window.Load += OnLoad;
        _window.Update += OnUpdate;
        _window.Render += OnRender;
        _window.FileDrop += OnFileDrop;
        _window.Closing += OnClosing;
    }

    private void OnLoad()
    {
        _window.MakeCurrent();
        _gl.Viewport(_window.FramebufferSize);
    }

    public void LoadRom(string sourcePath)
    {
        try
        {
            _core.LoadRom(sourcePath);
            _config.AddRecentRom(sourcePath);
            ConfigStore.Save(_config);
            _lastError = "";
            _window.Title = $"PocketGB — {_core.GameTitle} — mGBA";
            Log.Information("Loaded with mGBA: {Path}", sourcePath);
        }
        catch (Exception ex)
        {
            _lastError = ex.Message;
            Log.Error(ex, "mGBA could not load game file {Path}", sourcePath);
        }
    }

    public void RunFrames(int frames)
    {
        if (_disposed) return;
        _core.Muted = _config.Audio.Muted || (_turboActive && _config.General.MuteDuringTurbo);
        _core.RunFrames(frames);
    }

    public void RecordEmulatedFrames(int frames)
    {
        if (frames <= 0) return;
        _gameFramesInSample += frames;
        double elapsed = _gameFpsTimer.Elapsed.TotalSeconds;
        if (elapsed >= 0.5)
        {
            double measured = _gameFramesInSample / elapsed;
            _gameFps = _gameFps <= 0 ? measured : (_gameFps * 0.55) + (measured * 0.45);
            _gameFramesInSample = 0;
            _gameFpsTimer.Restart();
        }
    }

    private void OnFileDrop(string[] paths)
    {
        foreach (string path in paths)
        {
            string extension = Path.GetExtension(path);
            if (extension.Equals(".gba", StringComparison.OrdinalIgnoreCase) ||
                extension.Equals(".gb", StringComparison.OrdinalIgnoreCase) ||
                extension.Equals(".gbc", StringComparison.OrdinalIgnoreCase) ||
                extension.Equals(".sgb", StringComparison.OrdinalIgnoreCase) ||
                extension.Equals(".zip", StringComparison.OrdinalIgnoreCase))
            {
                LoadRom(path);
                return;
            }
        }
    }

    private void OnUpdate(double delta)
    {
        _imgui.MakeCurrent();
        _turboActive = false;

        if (ImGui.GetIO().WantCaptureKeyboard)
        {
            _core.SetKeys(0);
            return;
        }

        IKeyboard? keyboard = _input.Keyboards.Count > 0 ? _input.Keyboards[0] : null;
        IGamepad? gamepad = _input.Gamepads.Count > 0 ? _input.Gamepads[0] : null;

        uint keys = 0;
        if (IsDown(Key.Z, keyboard) || IsGamepadDown(ButtonName.A, gamepad)) keys |= 1u << 0; // A
        if (IsDown(Key.X, keyboard) || IsGamepadDown(ButtonName.B, gamepad)) keys |= 1u << 1; // B
        if (IsDown(Key.ShiftRight, keyboard) || IsGamepadDown(ButtonName.Back, gamepad)) keys |= 1u << 2; // Select
        if (IsDown(Key.Enter, keyboard) || IsGamepadDown(ButtonName.Start, gamepad)) keys |= 1u << 3; // Start
        if (IsDown(Key.Right, keyboard) || IsGamepadDown(ButtonName.DPadRight, gamepad)) keys |= 1u << 4;
        if (IsDown(Key.Left, keyboard) || IsGamepadDown(ButtonName.DPadLeft, gamepad)) keys |= 1u << 5;
        if (IsDown(Key.Up, keyboard) || IsGamepadDown(ButtonName.DPadUp, gamepad)) keys |= 1u << 6;
        if (IsDown(Key.Down, keyboard) || IsGamepadDown(ButtonName.DPadDown, gamepad)) keys |= 1u << 7;
        if (IsDown(Key.S, keyboard) || IsGamepadShoulder(right: true, gamepad)) keys |= 1u << 8; // R
        if (IsDown(Key.A, keyboard) || IsGamepadShoulder(right: false, gamepad)) keys |= 1u << 9; // L
        _core.SetKeys(keys);

        _turboActive = IsDown(Key.Tab, keyboard);
        if (WasPressed(Key.Space, keyboard)) _core.IsPaused = !_core.IsPaused;
        if (WasPressed(Key.F5, keyboard)) RunUiAction(_core.SaveState, "Save state");
        if (WasPressed(Key.F8, keyboard)) RunUiAction(() =>
        {
            if (!_core.LoadState()) throw new FileNotFoundException("No mGBA quick-save state exists for this game yet.");
        }, "Load state");
        if (WasPressed(Key.F9, keyboard)) RunUiAction(_core.Reset, "Reset");
    }

    private static bool IsDown(Key key, IKeyboard? keyboard) => keyboard?.IsKeyPressed(key) ?? false;

    private static bool IsGamepadDown(ButtonName name, IGamepad? gamepad)
    {
        if (gamepad == null) return false;
        foreach (Button button in gamepad.Buttons)
            if (button.Name == name && button.Pressed) return true;
        return false;
    }

    private static bool IsGamepadShoulder(bool right, IGamepad? gamepad)
    {
        if (gamepad == null) return false;
        foreach (Button button in gamepad.Buttons)
        {
            if (!button.Pressed) continue;
            string name = button.Name.ToString();
            bool sideMatches = right
                ? name.Contains("Right", StringComparison.OrdinalIgnoreCase)
                : name.Contains("Left", StringComparison.OrdinalIgnoreCase);
            bool shoulder = name.Contains("Shoulder", StringComparison.OrdinalIgnoreCase) ||
                name.Contains("Trigger", StringComparison.OrdinalIgnoreCase);
            if (sideMatches && shoulder) return true;
        }
        return false;
    }

    private bool WasPressed(Key key, IKeyboard? keyboard)
    {
        bool down = IsDown(key, keyboard);
        bool previous = _previousKeys.TryGetValue(key, out bool wasDown) && wasDown;
        _previousKeys[key] = down;
        return down && !previous;
    }

    private void RunUiAction(Action action, string name)
    {
        try
        {
            if (!_core.HasRom) return;
            action();
            _lastError = "";
        }
        catch (Exception ex)
        {
            _lastError = ex.Message;
            Log.Warning(ex, "mGBA {Action} failed", name);
        }
    }

    private void OnRender(double delta)
    {
        _window.MakeCurrent();
        var size = _window.FramebufferSize;
        uint width = (uint)Math.Max(1, size.X);
        uint height = (uint)Math.Max(1, size.Y);
        _gl.Viewport(0, 0, width, height);
        _gl.ClearColor(0.035f, 0.055f, 0.048f, 1f);
        _gl.Clear(ClearBufferMask.ColorBufferBit);

        if (delta > 0 && double.IsFinite(delta))
        {
            double instantaneous = 1.0 / delta;
            _renderFps = _renderFps <= 0 ? instantaneous : (_renderFps * 0.88) + (instantaneous * 0.12);
        }

        _imgui.MakeCurrent();
        _imgui.Update((float)delta);

        float toolbarHeight = 38f;
        var view = ImGui.GetMainViewport();
        float scaleX = size.X / Math.Max(1f, view.Size.X);
        float scaleY = size.Y / Math.Max(1f, view.Size.Y);
        int toolbarPixels = (int)Math.Clamp(toolbarHeight * scaleY, 24f, size.Y - 1);
        int areaHeight = Math.Max(1, size.Y - toolbarPixels);

        if (_core.HasRom && _core.FrameBuffer.Length > 0)
        {
            ComputeFrameViewport((int)width, areaHeight, _core.FrameWidth, _core.FrameHeight,
                out int x, out int y, out int w, out int h);
            _gl.Viewport(x, y, (uint)w, (uint)h);
            _renderer.Render(_core.FrameBuffer, _core.FrameWidth, _core.FrameHeight);
        }

        _gl.Viewport(0, 0, width, height);
        DrawToolbar();
        DrawPerformanceOverlay();
        _fileBrowser.Draw();
        DrawError();
        _imgui.Render();

        if (++_titleRefresh >= 30)
        {
            _titleRefresh = 0;
            string name = _core.HasRom ? _core.GameTitle : "No game";
            _window.Title = $"PocketGB — {name} — Render {_renderFps:0} FPS | Game {_gameFps:0.0} FPS";
        }
    }

    private void DrawToolbar()
    {
        var view = ImGui.GetMainViewport();
        ImGui.SetNextWindowPos(view.Pos);
        ImGui.SetNextWindowSize(new Vector2(view.Size.X, 38f));
        const ImGuiWindowFlags flags =
            ImGuiWindowFlags.NoTitleBar | ImGuiWindowFlags.NoResize | ImGuiWindowFlags.NoMove |
            ImGuiWindowFlags.NoScrollbar | ImGuiWindowFlags.NoCollapse | ImGuiWindowFlags.NoSavedSettings;

        if (ImGui.Begin("##mgba-toolbar", flags))
        {
            if (ImGui.Button("Open")) _fileBrowser.Open();
            ImGui.SameLine();

            bool hasRom = _core.HasRom;
            if (!hasRom) ImGui.BeginDisabled();
            if (ImGui.Button(_core.IsPaused ? "Play" : "Pause"))
                _core.IsPaused = !_core.IsPaused;
            ImGui.SameLine();
            if (ImGui.Button("Reset")) RunUiAction(_core.Reset, "Reset");
            ImGui.SameLine();
            if (ImGui.Button("Save")) RunUiAction(_core.SaveState, "Save state");
            ImGui.SameLine();
            if (ImGui.Button("Load")) RunUiAction(() =>
            {
                if (!_core.LoadState()) throw new FileNotFoundException("No quick-save state exists for this game yet.");
            }, "Load state");
            if (!hasRom) ImGui.EndDisabled();

            ImGui.SameLine();
            double speed = _config.General.SpeedMultiplier;
            if (ImGui.Button($"Speed {speed:0.##}x"))
            {
                _config.General.SpeedMultiplier = speed < 0.99 ? 1.0 : speed < 1.99 ? 2.0 : 0.5;
                ConfigStore.Save(_config);
            }
            ImGui.SameLine();
            if (ImGui.Button("Back to GB Window")) _window.Close();
            ImGui.SameLine();
            ImGui.TextDisabled(hasRom
                ? $"{_core.PlatformName}  |  {_core.GameTitle}  |  Tab: turbo"
                : "mGBA core ready — open a .gba, .gb, .gbc or ZIP game");
        }
        ImGui.End();
    }

    private void DrawPerformanceOverlay()
    {
        var view = ImGui.GetMainViewport();
        ImGui.SetNextWindowPos(new Vector2(view.Pos.X + view.Size.X - 12f, view.Pos.Y + 46f),
            ImGuiCond.Always, new Vector2(1f, 0f));
        ImGui.SetNextWindowBgAlpha(0.78f);

        const ImGuiWindowFlags flags =
            ImGuiWindowFlags.NoTitleBar | ImGuiWindowFlags.NoResize | ImGuiWindowFlags.NoMove |
            ImGuiWindowFlags.NoScrollbar | ImGuiWindowFlags.NoSavedSettings |
            ImGuiWindowFlags.NoFocusOnAppearing | ImGuiWindowFlags.NoNav |
            ImGuiWindowFlags.NoInputs | ImGuiWindowFlags.AlwaysAutoResize;

        if (ImGui.Begin("##mgba-performance", flags))
        {
            ImGui.Text($"RENDER  {_renderFps:0} FPS");
            ImGui.Text($"GAME    {_gameFps:0.0} FPS");
            double speed = _core.NominalFrameRate > 0 ? _gameFps / _core.NominalFrameRate : 0;
            ImGui.TextColored(_turboActive ? new Vector4(0.48f, 0.95f, 0.62f, 1f) :
                new Vector4(0.78f, 0.86f, 0.81f, 1f),
                string.Format(_turboActive ? "TURBO  {0:0.00}x" : "SPEED  {0:0.00}x", speed));
        }
        ImGui.End();
    }

    private void DrawError()
    {
        if (string.IsNullOrWhiteSpace(_lastError)) return;
        var view = ImGui.GetMainViewport();
        ImGui.SetNextWindowPos(view.Pos + new Vector2(16f, 48f), ImGuiCond.Always);
        ImGui.SetNextWindowBgAlpha(0.92f);
        if (ImGui.Begin("mGBA message", ImGuiWindowFlags.AlwaysAutoResize | ImGuiWindowFlags.NoCollapse))
        {
            ImGui.TextWrapped(_lastError);
            if (ImGui.Button("Dismiss")) _lastError = "";
        }
        ImGui.End();
    }

    private static void ComputeFrameViewport(int areaWidth, int areaHeight, int frameWidth, int frameHeight,
        out int x, out int y, out int w, out int h)
    {
        float scale = Math.Min(areaWidth / (float)frameWidth, areaHeight / (float)frameHeight);
        if (scale >= 1f) scale = MathF.Floor(scale);
        w = Math.Max(1, (int)(frameWidth * scale));
        h = Math.Max(1, (int)(frameHeight * scale));
        x = (areaWidth - w) / 2;
        y = (areaHeight - h) / 2;
    }

    private void OnClosing()
    {
        if (!_suppressReturn)
            _returnToGameboySharp?.Invoke();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _suppressReturn = true;

        _window.Load -= OnLoad;
        _window.Update -= OnUpdate;
        _window.Render -= OnRender;
        _window.FileDrop -= OnFileDrop;
        _window.Closing -= OnClosing;

        _core.Dispose();
        _window.MakeCurrent();
        _renderer.Dispose();
        _imgui.Dispose();
        _input.Dispose();
        _gl.Dispose();
        _window.Dispose();
    }

    /// <summary>Minimal dynamic-size OpenGL texture presenter; the emulator core remains graphics-API agnostic.</summary>
    private sealed unsafe class MgbaFrameRenderer : IDisposable
    {
        private readonly GL _gl;
        private uint _vao;
        private uint _vbo;
        private uint _ebo;
        private uint _program;
        private uint _texture;
        private int _textureWidth;
        private int _textureHeight;
        private readonly bool _linearFilter;

        private static readonly float[] Vertices =
        {
            1f,  1f,  1f, 0f,
            1f, -1f,  1f, 1f,
           -1f, -1f,  0f, 1f,
           -1f,  1f,  0f, 0f
        };
        private static readonly uint[] Indices = { 0, 1, 3, 1, 2, 3 };

        private const string VertexSource = @"#version 330 core
layout (location = 0) in vec2 aPosition;
layout (location = 1) in vec2 aTexCoord;
out vec2 vTexCoord;
void main()
{
    gl_Position = vec4(aPosition, 0.0, 1.0);
    vTexCoord = aTexCoord;
}";
        private const string FragmentSource = @"#version 330 core
in vec2 vTexCoord;
out vec4 FragColor;
uniform sampler2D uScreen;
void main()
{
    FragColor = texture(uScreen, vTexCoord);
}";

        public MgbaFrameRenderer(GL gl, bool linearFilter)
        {
            _gl = gl;
            _linearFilter = linearFilter;
            Initialize();
        }

        private void Initialize()
        {
            _vao = _gl.GenVertexArray();
            _gl.BindVertexArray(_vao);

            _vbo = _gl.GenBuffer();
            _gl.BindBuffer(BufferTargetARB.ArrayBuffer, _vbo);
            fixed (float* vertices = Vertices)
                _gl.BufferData(BufferTargetARB.ArrayBuffer, (uint)(Vertices.Length * sizeof(float)),
                    vertices, BufferUsageARB.StaticDraw);

            _ebo = _gl.GenBuffer();
            _gl.BindBuffer(BufferTargetARB.ElementArrayBuffer, _ebo);
            fixed (uint* indices = Indices)
                _gl.BufferData(BufferTargetARB.ElementArrayBuffer, (uint)(Indices.Length * sizeof(uint)),
                    indices, BufferUsageARB.StaticDraw);

            _gl.VertexAttribPointer(0, 2, VertexAttribPointerType.Float, false, 4 * sizeof(float), null);
            _gl.EnableVertexAttribArray(0);
            _gl.VertexAttribPointer(1, 2, VertexAttribPointerType.Float, false, 4 * sizeof(float),
                (void*)(2 * sizeof(float)));
            _gl.EnableVertexAttribArray(1);

            _program = CreateProgram();
            int sampler = _gl.GetUniformLocation(_program, "uScreen");
            _gl.UseProgram(_program);
            if (sampler >= 0) _gl.Uniform1(sampler, 0);

            _texture = _gl.GenTexture();
            _gl.BindTexture(TextureTarget.Texture2D, _texture);
            _gl.TexParameter(TextureTarget.Texture2D, TextureParameterName.TextureWrapS,
                (int)TextureWrapMode.ClampToEdge);
            _gl.TexParameter(TextureTarget.Texture2D, TextureParameterName.TextureWrapT,
                (int)TextureWrapMode.ClampToEdge);
            _gl.TexParameter(TextureTarget.Texture2D, TextureParameterName.TextureMinFilter,
                (int)(_linearFilter ? TextureMinFilter.Linear : TextureMinFilter.Nearest));
            _gl.TexParameter(TextureTarget.Texture2D, TextureParameterName.TextureMagFilter,
                (int)(_linearFilter ? TextureMagFilter.Linear : TextureMagFilter.Nearest));
            _gl.TexImage2D(TextureTarget.Texture2D, 0, InternalFormat.Rgba, 160, 144, 0,
                PixelFormat.Rgba, PixelType.UnsignedByte, null);
            _textureWidth = 160;
            _textureHeight = 144;
        }

        public void Render(uint[] pixels, int width, int height)
        {
            if (width != _textureWidth || height != _textureHeight)
            {
                _gl.BindTexture(TextureTarget.Texture2D, _texture);
                _gl.TexImage2D(TextureTarget.Texture2D, 0, InternalFormat.Rgba, (uint)width, (uint)height,
                    0, PixelFormat.Rgba, PixelType.UnsignedByte, null);
                _textureWidth = width;
                _textureHeight = height;
            }

            _gl.ActiveTexture(TextureUnit.Texture0);
            _gl.BindTexture(TextureTarget.Texture2D, _texture);
            fixed (uint* buffer = pixels)
            {
                _gl.TexSubImage2D(TextureTarget.Texture2D, 0, 0, 0, (uint)width, (uint)height,
                    PixelFormat.Rgba, PixelType.UnsignedByte, buffer);
            }

            _gl.UseProgram(_program);
            _gl.BindVertexArray(_vao);
            _gl.DrawElements(PrimitiveType.Triangles, (uint)Indices.Length, DrawElementsType.UnsignedInt, null);
        }

        private uint CreateProgram()
        {
            uint vertex = Compile(ShaderType.VertexShader, VertexSource);
            uint fragment = Compile(ShaderType.FragmentShader, FragmentSource);
            uint program = _gl.CreateProgram();
            _gl.AttachShader(program, vertex);
            _gl.AttachShader(program, fragment);
            _gl.LinkProgram(program);
            _gl.GetProgram(program, GLEnum.LinkStatus, out int status);
            string log = _gl.GetProgramInfoLog(program);
            _gl.DeleteShader(vertex);
            _gl.DeleteShader(fragment);
            if (status == 0)
            {
                _gl.DeleteProgram(program);
                throw new InvalidOperationException("mGBA OpenGL shader link failed: " + log);
            }
            if (!string.IsNullOrWhiteSpace(log))
                Log.Warning("mGBA OpenGL shader linker reported: {Message}", log);
            return program;
        }

        private uint Compile(ShaderType type, string source)
        {
            uint shader = _gl.CreateShader(type);
            _gl.ShaderSource(shader, source);
            _gl.CompileShader(shader);
            _gl.GetShader(shader, GLEnum.CompileStatus, out int status);
            string log = _gl.GetShaderInfoLog(shader);
            if (status == 0)
            {
                _gl.DeleteShader(shader);
                throw new InvalidOperationException($"mGBA OpenGL {type} shader failed: {log}");
            }
            if (!string.IsNullOrWhiteSpace(log))
                Log.Warning("mGBA OpenGL shader compiler reported: {Message}", log);
            return shader;
        }

        public void Dispose()
        {
            if (_texture != 0) _gl.DeleteTexture(_texture);
            if (_program != 0) _gl.DeleteProgram(_program);
            if (_vbo != 0) _gl.DeleteBuffer(_vbo);
            if (_ebo != 0) _gl.DeleteBuffer(_ebo);
            if (_vao != 0) _gl.DeleteVertexArray(_vao);
        }
    }
}
