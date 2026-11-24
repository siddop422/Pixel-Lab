$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$vendor = Join-Path $root "vendor/GameboySharp"
$configPath = Join-Path $vendor "Config/EmulatorConfig.cs"
$runtimePath = Join-Path $vendor "Config/RuntimeConfig.cs"
$settingsPath = Join-Path $vendor "UI/SettingsDialog.cs"
$windowPath = Join-Path $vendor "UI/GameWindow.cs"
$rendererPath = Join-Path $vendor "UI/ScreenRenderer.cs"
$shaderPath = Join-Path $vendor "shaders/screen.frag"

foreach ($path in @($configPath, $runtimePath, $settingsPath, $windowPath, $rendererPath, $shaderPath)) {
    if (-not (Test-Path $path)) { throw "Missing expected graphics source file: $path" }
}

function Replace-ExactlyOnce([string]$Source, [string]$Old, [string]$New, [string]$Label) {
    $count = ([regex]::Matches($Source, [regex]::Escape($Old))).Count
    if ($count -ne 1) { throw "Expected one $Label anchor, found $count. The upstream source changed; refusing a partial patch." }
    return $Source.Replace($Old, $New)
}

# Convert the compact, version-controlled icon source into a native ICO during every build.
$iconSource = Join-Path $root "assets/PocketGB.ico.b64"
$iconOutput = Join-Path $root "assets/PocketGB.ico"
if (-not (Test-Path $iconSource)) { throw "Missing PocketGB icon source: $iconSource" }
$iconBytes = [Convert]::FromBase64String(([System.IO.File]::ReadAllText($iconSource)).Trim())
[System.IO.File]::WriteAllBytes($iconOutput, $iconBytes)

# Embed the same PocketGB icon into the Windows application executable.
$projectPath = Join-Path $vendor "GameboySharp.csproj"
$project = [System.IO.File]::ReadAllText($projectPath)
if (-not $project.Contains('<ApplicationIcon Condition="''$(RuntimeIdentifier)'' == ''win-x64''">PocketGB.ico</ApplicationIcon>')) {
    $project = Replace-ExactlyOnce $project '    <Nullable>enable</Nullable>' @'
    <Nullable>enable</Nullable>
    <ApplicationIcon Condition="'$(RuntimeIdentifier)' == 'win-x64'">PocketGB.ico</ApplicationIcon>
'@ "Windows executable icon project setting"
}
[System.IO.File]::Copy($iconOutput, (Join-Path $vendor "PocketGB.ico"), $true)
[System.IO.File]::WriteAllText($projectPath, $project, [System.Text.UTF8Encoding]::new($false))

# Persisted display settings. Defaults intentionally preserve the existing lightweight pixel-perfect look.
$config = [System.IO.File]::ReadAllText($configPath)
$config = Replace-ExactlyOnce $config '    public class EmulatorConfig' @'
    public enum VideoUpscaleMode
    {
        PixelPerfect,
        Bilinear,
        SharpBilinear
    }

    public class EmulatorConfig
'@ "video upscaling enum anchor"

$videoPattern = '(?s)    public class VideoConfig\s*\{.*?\n    \}'
if ([regex]::Matches($config, $videoPattern).Count -ne 1) {
    throw "Could not uniquely locate VideoConfig. Refusing to overwrite an unknown settings schema."
}
$videoBlock = @'
    public class VideoConfig
    {
        public DmgPalettePreset Palette { get; set; } = DmgPalettePreset.Green;
        public bool IntegerScale { get; set; } = true;
        public bool LockAspectRatio { get; set; } = true;
        public bool ScanlineShader { get; set; } = false;

        /// <summary>GPU sampling method used when enlarging the native 160x144 frame.</summary>
        public VideoUpscaleMode UpscaleMode { get; set; } = VideoUpscaleMode.PixelPerfect;

        /// <summary>Experimental temporal blending of the previous and current frames.</summary>
        public bool FrameGeneration { get; set; } = false;
        public float FrameBlendAmount { get; set; } = 0.25f;

        public bool LcdGrid { get; set; } = false;
        public bool CrtCurve { get; set; } = false;
        public float Brightness { get; set; } = 1.0f;
        public float Saturation { get; set; } = 1.0f;

        public bool VSync { get; set; } = false;
        public bool Fullscreen { get; set; } = false;
    }
'@
$config = [regex]::Replace($config, $videoPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $videoBlock }, 1)
[System.IO.File]::WriteAllText($configPath, $config, [System.Text.UTF8Encoding]::new($false))

# Wire the saved values into the live renderer.
$runtime = [System.IO.File]::ReadAllText($runtimePath)
$runtime = Replace-ExactlyOnce $runtime '            renderer.Scanlines = config.Video.ScanlineShader;' @'
            renderer.Scanlines = config.Video.ScanlineShader;
            renderer.UpscaleMode = config.Video.UpscaleMode;
            renderer.FrameGeneration = config.Video.FrameGeneration;
            renderer.FrameBlendAmount = config.Video.FrameBlendAmount;
            renderer.LcdGrid = config.Video.LcdGrid;
            renderer.CrtCurve = config.Video.CrtCurve;
            renderer.Brightness = config.Video.Brightness;
            renderer.Saturation = config.Video.Saturation;
'@ "runtime video settings"
[System.IO.File]::WriteAllText($runtimePath, $runtime, [System.Text.UTF8Encoding]::new($false))

# The settings modal controls the host window through explicit callbacks; the emulator core remains
# independent of Silk.NET window APIs.
$settings = [System.IO.File]::ReadAllText($settingsPath)
$settings = Replace-ExactlyOnce $settings '        private readonly Action _persist;' @'
        private readonly Action _persist;
        private readonly Action<int, int> _resizeWindow;
        private readonly Action<bool> _setVSync;
        private readonly Action<bool> _setFullscreen;
'@ "settings callback fields"

$settings = Replace-ExactlyOnce $settings @'
        public SettingsDialog(EmulatorConfig config, Emulator emulator, ScreenRenderer renderer,
                              IInputContext input, Action persist)
'@ @'
        public SettingsDialog(EmulatorConfig config, Emulator emulator, ScreenRenderer renderer,
                              IInputContext input, Action persist, Action<int, int> resizeWindow,
                              Action<bool> setVSync, Action<bool> setFullscreen)
'@ "settings constructor signature"

$settings = Replace-ExactlyOnce $settings '            _persist = persist;' @'
            _persist = persist;
            _resizeWindow = resizeWindow;
            _setVSync = setVSync;
            _setFullscreen = setFullscreen;
'@ "settings callback initialization"

$videoMethodStart = $settings.IndexOf("        private void DrawVideoTab()")
$generalMethodStart = $settings.IndexOf("        private void DrawGeneralTab()", $videoMethodStart)
if ($videoMethodStart -lt 0 -or $generalMethodStart -lt 0) {
    throw "Could not find the Video and General settings methods."
}
$newVideoMethod = @'
        private void DrawVideoTab()
        {
            ImGui.SeparatorText("Display");
            string[] resolutions = { "640 x 576 (4x)", "800 x 720 (5x)", "960 x 864 (6x)", "1280 x 720", "1600 x 900" };
            int[] widths = { 640, 800, 960, 1280, 1600 };
            int[] heights = { 576, 720, 864, 720, 900 };
            int resolution = 0;
            for (int i = 0; i < widths.Length; i++)
            {
                if (_config.WindowWidth == widths[i] && _config.WindowHeight == heights[i]) { resolution = i; break; }
            }
            if (ImGui.Combo("Window resolution", ref resolution, resolutions, resolutions.Length))
            {
                _resizeWindow(widths[resolution], heights[resolution]);
                _persist();
            }

            bool fullscreen = _config.Video.Fullscreen;
            if (ImGui.Checkbox("Fullscreen", ref fullscreen))
            {
                _config.Video.Fullscreen = fullscreen;
                _setFullscreen(fullscreen);
                _persist();
            }

            bool vsync = _config.Video.VSync;
            if (ImGui.Checkbox("V-Sync", ref vsync))
            {
                _config.Video.VSync = vsync;
                _setVSync(vsync);
                _persist();
            }
            ImGui.TextDisabled("V-Sync synchronizes presentation with your monitor.");

            ImGui.SeparatorText("Custom window resolution");
            int customWidth = Math.Clamp(_config.WindowWidth, 320, 3840);
            int customHeight = Math.Clamp(_config.WindowHeight, 288, 2160);
            ImGui.InputInt("Width (px)", ref customWidth);
            ImGui.InputInt("Height (px)", ref customHeight);
            customWidth = Math.Clamp(customWidth, 320, 3840);
            customHeight = Math.Clamp(customHeight, 288, 2160);
            if (ImGui.Button("Apply custom resolution"))
            {
                _resizeWindow(customWidth, customHeight);
                _persist();
            }
            ImGui.SameLine();
            if (ImGui.Button("Reset to 640 x 576"))
            {
                _resizeWindow(640, 576);
                _persist();
            }
            ImGui.TextDisabled("These settings change the application window size, not the Game Boy's native 160 x 144 resolution.");

            ImGui.SeparatorText("Scaling and upscaling");
            string[] palettes = { "Green", "Grey", "Pocket", "Yellow" };
            int palette = (int)_config.Video.Palette;
            if (ImGui.Combo("DMG palette", ref palette, palettes, palettes.Length))
                _config.Video.Palette = (DmgPalettePreset)palette;

            bool integerScale = _config.Video.IntegerScale;
            if (ImGui.Checkbox("Integer scaling (pixel-perfect)", ref integerScale))
                _config.Video.IntegerScale = integerScale;

            bool lockAspect = _config.Video.LockAspectRatio;
            if (ImGui.Checkbox("Preserve Game Boy 10:9 aspect ratio", ref lockAspect))
                _config.Video.LockAspectRatio = lockAspect;

            string[] upscalers = { "Nearest / pixel-perfect", "Bilinear smooth", "Sharp bilinear" };
            int upscale = (int)_config.Video.UpscaleMode;
            if (ImGui.Combo("Upscaling filter", ref upscale, upscalers, upscalers.Length))
                _config.Video.UpscaleMode = (VideoUpscaleMode)upscale;
            ImGui.TextDisabled("Filters enlarge the original 160 x 144 image; they cannot create missing source detail.");

            ImGui.SeparatorText("Post-processing");
            bool scanlines = _config.Video.ScanlineShader;
            if (ImGui.Checkbox("Scanline effect", ref scanlines))
                _config.Video.ScanlineShader = scanlines;

            bool lcdGrid = _config.Video.LcdGrid;
            if (ImGui.Checkbox("LCD pixel grid", ref lcdGrid))
                _config.Video.LcdGrid = lcdGrid;

            bool crtCurve = _config.Video.CrtCurve;
            if (ImGui.Checkbox("CRT curvature and vignette", ref crtCurve))
                _config.Video.CrtCurve = crtCurve;

            float brightness = _config.Video.Brightness;
            if (ImGui.SliderFloat("Brightness", ref brightness, 0.5f, 1.5f))
                _config.Video.Brightness = brightness;

            float saturation = _config.Video.Saturation;
            if (ImGui.SliderFloat("Saturation", ref saturation, 0.0f, 2.0f))
                _config.Video.Saturation = saturation;

            ImGui.SeparatorText("Quick graphics profiles");
            if (ImGui.Button("Low-end / maximum performance"))
            {
                _config.Video.IntegerScale = true;
                _config.Video.LockAspectRatio = true;
                _config.Video.UpscaleMode = VideoUpscaleMode.PixelPerfect;
                _config.Video.FrameGeneration = false;
                _config.Video.FrameBlendAmount = 0.0f;
                _config.Video.LcdGrid = false;
                _config.Video.CrtCurve = false;
                _config.Video.ScanlineShader = false;
                _config.Video.Brightness = 1.0f;
                _config.Video.Saturation = 1.0f;
                _config.Video.VSync = false;
                _setVSync(false);
                _persist();
            }
            ImGui.SameLine();
            if (ImGui.Button("Retro display"))
            {
                _config.Video.IntegerScale = true;
                _config.Video.LockAspectRatio = true;
                _config.Video.UpscaleMode = VideoUpscaleMode.PixelPerfect;
                _config.Video.FrameGeneration = false;
                _config.Video.LcdGrid = true;
                _config.Video.CrtCurve = false;
                _config.Video.ScanlineShader = true;
                _persist();
            }
            ImGui.TextDisabled("Low-end mode disables extra shader passes and frame blending.");
            
            ImGui.SeparatorText("Frame presentation");
            bool frameGeneration = _config.Video.FrameGeneration;
            if (ImGui.Checkbox("Experimental temporal frame blending", ref frameGeneration))
                _config.Video.FrameGeneration = frameGeneration;

            float blend = _config.Video.FrameBlendAmount;
            if (ImGui.SliderFloat("Blend amount", ref blend, 0.0f, 0.5f))
                _config.Video.FrameBlendAmount = blend;
            ImGui.TextDisabled("Blends adjacent frames and can create ghosting. It does not interpolate motion or double the real game FPS.");

            ImGui.SeparatorText("Graphics renderer backend");
            ImGui.TextUnformatted("Active graphics API: OpenGL 3.3 Core");
            ImGui.TextWrapped($"GPU vendor: {_renderer.GraphicsVendor}");
            ImGui.TextWrapped($"GPU renderer: {_renderer.GraphicsRenderer}");
            ImGui.TextWrapped($"Driver / OpenGL version: {_renderer.GraphicsVersion}");
            ImGui.TextDisabled("Only OpenGL 3.3 is currently implemented as a graphics backend. Vulkan and Direct3D are not selectable in this build; the Audio tab has separate SDL / OpenAL backend selection.");
        }

'@
$settings = $settings.Substring(0, $videoMethodStart) + $newVideoMethod + $settings.Substring($generalMethodStart)

# Make room for the extra controls while respecting smaller displays.
$settings = [regex]::Replace(
    $settings,
    'var dialogSize = new Vector2\(Math\.Min\(520f, Math\.Max\(420f, viewport\.Size\.X - 32f\)\), Math\.Min\(420f, Math\.Max\(320f, viewport\.Size\.Y - 76f\)\)\);',
    'var dialogSize = new Vector2(Math.Min(760f, Math.Max(520f, viewport.Size.X - 32f)), Math.Min(700f, Math.Max(500f, viewport.Size.Y - 76f)));')
[System.IO.File]::WriteAllText($settingsPath, $settings, [System.Text.UTF8Encoding]::new($false))

# Add display callbacks and restore the last windowed size after leaving fullscreen.
$window = [System.IO.File]::ReadAllText($windowPath)
$window = Replace-ExactlyOnce $window '        private bool _pausedByFocusLoss;' @'
        private int _windowedWidth;
        private int _windowedHeight;
        private bool _pausedByFocusLoss;
'@ "windowed size fields"

$window = Replace-ExactlyOnce $window '            int initialHeight = Math.Max(GameboyConstants.ScreenHeight, _config.WindowHeight);' @'
            int initialHeight = Math.Max(GameboyConstants.ScreenHeight, _config.WindowHeight);
            _windowedWidth = initialWidth;
            _windowedHeight = initialHeight;
'@ "initial window dimensions"

$window = Replace-ExactlyOnce $window '            options.VSync = false; // We handle frame pacing manually in the main loop' @'
            options.VSync = _config.Video.VSync;
            options.WindowState = _config.Video.Fullscreen ? WindowState.Fullscreen : WindowState.Normal;
'@ "window creation VSync setting"

$window = Replace-ExactlyOnce $window @'
            _settingsDialog = new SettingsDialog(_config, _emulator, _renderer, _inputContext,
                                                 () => ConfigStore.Save(_config));
'@ @'
            _settingsDialog = new SettingsDialog(_config, _emulator, _renderer, _inputContext,
                                                 () => ConfigStore.Save(_config), ApplyWindowResolution,
                                                 ApplyVSync, ApplyFullscreen);
'@ "settings dialog construction"

$window = Replace-ExactlyOnce $window @'
        private void OnWindowResize(Vector2D<int> newSize)
        {
            if (newSize.X > 0 && newSize.Y > 0)
            {
                _config.WindowWidth = newSize.X;
                _config.WindowHeight = newSize.Y;
            }
        }
'@ @'
        private void OnWindowResize(Vector2D<int> newSize)
        {
            if (newSize.X > 0 && newSize.Y > 0 && _window.WindowState == WindowState.Normal)
            {
                _windowedWidth = newSize.X;
                _windowedHeight = newSize.Y;
                _config.WindowWidth = newSize.X;
                _config.WindowHeight = newSize.Y;
            }
        }

        private void ApplyWindowResolution(int width, int height)
        {
            _windowedWidth = Math.Max(GameboyConstants.ScreenWidth * 2, width);
            _windowedHeight = Math.Max(GameboyConstants.ScreenHeight * 2, height);
            _config.WindowWidth = _windowedWidth;
            _config.WindowHeight = _windowedHeight;
            if (_window.WindowState == WindowState.Normal)
                _window.Size = new Vector2D<int>(_windowedWidth, _windowedHeight);
        }

        private void ApplyVSync(bool enabled)
        {
            _config.Video.VSync = enabled;
            _window.VSync = enabled;
        }

        private void ApplyFullscreen(bool enabled)
        {
            if (enabled)
            {
                if (_window.WindowState == WindowState.Normal)
                {
                    _windowedWidth = _window.Size.X;
                    _windowedHeight = _window.Size.Y;
                    _config.WindowWidth = _windowedWidth;
                    _config.WindowHeight = _windowedHeight;
                }
                _window.WindowState = WindowState.Fullscreen;
            }
            else
            {
                _window.WindowState = WindowState.Normal;
                _window.Size = new Vector2D<int>(_windowedWidth, _windowedHeight);
            }
            _config.Video.Fullscreen = enabled;
        }
'@ "window resize handler and display actions"
[System.IO.File]::WriteAllText($windowPath, $window, [System.Text.UTF8Encoding]::new($false))

# A shader-based renderer with native, bilinear and sharp-bilinear sampling, post-processing,
# optional temporal frame blending, and live GPU/driver diagnostics. The default is unchanged:
# nearest-neighbour sampling, no effects, no frame blending.
$renderer = @'
using System;
using Silk.NET.OpenGL;

namespace GameboySharp
{
    public class ScreenRenderer : IDisposable
    {
        private readonly GL _gl;
        private uint _vao;
        private uint _vbo;
        private uint _ebo;
        private uint _shaderProgram;
        private uint _texture;
        private uint _previousTexture;
        private readonly uint[] _previousFrameBuffer = new uint[GameboyConstants.ScreenWidth * GameboyConstants.ScreenHeight];
        private bool _hasPreviousFrame;
        private VideoUpscaleMode _upscaleMode = VideoUpscaleMode.PixelPerfect;

        private int _scanlineLocation = -1;
        private int _lcdGridLocation = -1;
        private int _crtLocation = -1;
        private int _brightnessLocation = -1;
        private int _saturationLocation = -1;
        private int _upscaleLocation = -1;
        private int _frameBlendLocation = -1;
        private int _frameBlendAmountLocation = -1;

        public bool Scanlines { get; set; }
        public bool LcdGrid { get; set; }
        public bool CrtCurve { get; set; }
        public bool FrameGeneration
        {
            get => _frameGeneration;
            set
            {
                if (value && !_frameGeneration) _hasPreviousFrame = false;
                _frameGeneration = value;
            }
        }
        private bool _frameGeneration;
        public float FrameBlendAmount { get; set; } = 0.25f;
        public float Brightness { get; set; } = 1.0f;
        public float Saturation { get; set; } = 1.0f;
        public string GraphicsVendor { get; private set; } = "Unknown";
        public string GraphicsRenderer { get; private set; } = "Unknown";
        public string GraphicsVersion { get; private set; } = "Unknown";

        public VideoUpscaleMode UpscaleMode
        {
            get => _upscaleMode;
            set
            {
                _upscaleMode = value;
                ApplyTextureFilter();
            }
        }

        private static readonly float[] Vertices =
        {
             1.0f,  1.0f, 1.0f, 0.0f,
             1.0f, -1.0f, 1.0f, 1.0f,
            -1.0f, -1.0f, 0.0f, 1.0f,
            -1.0f,  1.0f, 0.0f, 0.0f
        };

        private static readonly uint[] Indices = { 0, 1, 3, 1, 2, 3 };

        public ScreenRenderer(GL gl) { _gl = gl; }

        public unsafe void Load()
        {
            GraphicsVendor = SafeGlString(GLEnum.Vendor);
            GraphicsRenderer = SafeGlString(GLEnum.Renderer);
            GraphicsVersion = SafeGlString(GLEnum.Version);

            _vao = _gl.GenVertexArray();
            _gl.BindVertexArray(_vao);

            _vbo = _gl.GenBuffer();
            _gl.BindBuffer(BufferTargetARB.ArrayBuffer, _vbo);
            fixed (void* p = Vertices)
                _gl.BufferData(BufferTargetARB.ArrayBuffer, (uint)(Vertices.Length * sizeof(float)), p, BufferUsageARB.StaticDraw);

            _ebo = _gl.GenBuffer();
            _gl.BindBuffer(BufferTargetARB.ElementArrayBuffer, _ebo);
            fixed (void* p = Indices)
                _gl.BufferData(BufferTargetARB.ElementArrayBuffer, (uint)(Indices.Length * sizeof(uint)), p, BufferUsageARB.StaticDraw);

            string shaderDir = System.IO.Path.Combine(AppContext.BaseDirectory, "shaders");
            string vertexSource = System.IO.File.ReadAllText(System.IO.Path.Combine(shaderDir, "screen.vert"));
            string fragmentSource = System.IO.File.ReadAllText(System.IO.Path.Combine(shaderDir, "screen.frag"));
            _shaderProgram = CreateShaderProgram(vertexSource, fragmentSource);

            _scanlineLocation = _gl.GetUniformLocation(_shaderProgram, "uScanlineStrength");
            _lcdGridLocation = _gl.GetUniformLocation(_shaderProgram, "uLcdGridStrength");
            _crtLocation = _gl.GetUniformLocation(_shaderProgram, "uCrtStrength");
            _brightnessLocation = _gl.GetUniformLocation(_shaderProgram, "uBrightness");
            _saturationLocation = _gl.GetUniformLocation(_shaderProgram, "uSaturation");
            _upscaleLocation = _gl.GetUniformLocation(_shaderProgram, "uUpscaleMode");
            _frameBlendLocation = _gl.GetUniformLocation(_shaderProgram, "uFrameBlend");
            _frameBlendAmountLocation = _gl.GetUniformLocation(_shaderProgram, "uFrameBlendAmount");
            int mainSampler = _gl.GetUniformLocation(_shaderProgram, "ourTexture");
            int previousSampler = _gl.GetUniformLocation(_shaderProgram, "uPreviousTexture");

            _gl.UseProgram(_shaderProgram);
            if (mainSampler >= 0) _gl.Uniform1(mainSampler, 0);
            if (previousSampler >= 0) _gl.Uniform1(previousSampler, 1);

            _gl.VertexAttribPointer(0, 2, VertexAttribPointerType.Float, false, 4 * sizeof(float), null);
            _gl.EnableVertexAttribArray(0);
            _gl.VertexAttribPointer(1, 2, VertexAttribPointerType.Float, false, 4 * sizeof(float), (void*)(2 * sizeof(float)));
            _gl.EnableVertexAttribArray(1);

            _texture = CreateFrameTexture();
            _previousTexture = CreateFrameTexture();
            _gl.ActiveTexture(TextureUnit.Texture0);
            ApplyTextureFilter();
        }

        private string SafeGlString(GLEnum name)
        {
            try
            {
                string value = _gl.GetStringS(name);
                return string.IsNullOrWhiteSpace(value) ? "Unavailable" : value;
            }
            catch
            {
                return "Unavailable";
            }
        }

        private unsafe uint CreateFrameTexture()
        {
            uint texture = _gl.GenTexture();
            _gl.BindTexture(TextureTarget.Texture2D, texture);
            _gl.TexParameter(TextureTarget.Texture2D, TextureParameterName.TextureWrapS, (int)TextureWrapMode.ClampToEdge);
            _gl.TexParameter(TextureTarget.Texture2D, TextureParameterName.TextureWrapT, (int)TextureWrapMode.ClampToEdge);
            _gl.TexImage2D(TextureTarget.Texture2D, 0, InternalFormat.Rgba,
                (uint)GameboyConstants.ScreenWidth, (uint)GameboyConstants.ScreenHeight,
                0, PixelFormat.Rgba, PixelType.UnsignedByte, null);
            return texture;
        }

        private void ApplyTextureFilter()
        {
            if (_texture == 0) return;
            bool linear = _upscaleMode != VideoUpscaleMode.PixelPerfect;
            _gl.ActiveTexture(TextureUnit.Texture0);
            _gl.BindTexture(TextureTarget.Texture2D, _texture);
            _gl.TexParameter(TextureTarget.Texture2D, TextureParameterName.TextureMinFilter,
                (int)(linear ? TextureMinFilter.Linear : TextureMinFilter.Nearest));
            _gl.TexParameter(TextureTarget.Texture2D, TextureParameterName.TextureMagFilter,
                (int)(linear ? TextureMagFilter.Linear : TextureMagFilter.Nearest));
            _gl.ActiveTexture(TextureUnit.Texture1);
            _gl.BindTexture(TextureTarget.Texture2D, _previousTexture);
            _gl.TexParameter(TextureTarget.Texture2D, TextureParameterName.TextureMinFilter,
                (int)(linear ? TextureMinFilter.Linear : TextureMinFilter.Nearest));
            _gl.TexParameter(TextureTarget.Texture2D, TextureParameterName.TextureMagFilter,
                (int)(linear ? TextureMagFilter.Linear : TextureMagFilter.Nearest));
            _gl.ActiveTexture(TextureUnit.Texture0);
        }

        public unsafe void Render(uint[] frameBuffer)
        {
            _gl.ActiveTexture(TextureUnit.Texture0);
            _gl.BindTexture(TextureTarget.Texture2D, _texture);
            fixed (uint* ptr = frameBuffer)
            {
                _gl.TexSubImage2D(TextureTarget.Texture2D, 0, 0, 0,
                    (uint)GameboyConstants.ScreenWidth, (uint)GameboyConstants.ScreenHeight,
                    PixelFormat.Rgba, PixelType.UnsignedByte, ptr);
            }

            if (FrameGeneration)
            {
                if (!_hasPreviousFrame)
                    Array.Copy(frameBuffer, _previousFrameBuffer, _previousFrameBuffer.Length);

                _gl.ActiveTexture(TextureUnit.Texture1);
                _gl.BindTexture(TextureTarget.Texture2D, _previousTexture);
                fixed (uint* previous = _previousFrameBuffer)
                {
                    _gl.TexSubImage2D(TextureTarget.Texture2D, 0, 0, 0,
                        (uint)GameboyConstants.ScreenWidth, (uint)GameboyConstants.ScreenHeight,
                        PixelFormat.Rgba, PixelType.UnsignedByte, previous);
                }
                _gl.ActiveTexture(TextureUnit.Texture0);
            }

            _gl.UseProgram(_shaderProgram);
            if (_scanlineLocation >= 0) _gl.Uniform1(_scanlineLocation, Scanlines ? 0.30f : 0.0f);
            if (_lcdGridLocation >= 0) _gl.Uniform1(_lcdGridLocation, LcdGrid ? 0.24f : 0.0f);
            if (_crtLocation >= 0) _gl.Uniform1(_crtLocation, CrtCurve ? 1.0f : 0.0f);
            if (_brightnessLocation >= 0) _gl.Uniform1(_brightnessLocation, Math.Clamp(Brightness, 0.5f, 1.5f));
            if (_saturationLocation >= 0) _gl.Uniform1(_saturationLocation, Math.Clamp(Saturation, 0.0f, 2.0f));
            if (_upscaleLocation >= 0) _gl.Uniform1(_upscaleLocation, (int)_upscaleMode);
            if (_frameBlendLocation >= 0) _gl.Uniform1(_frameBlendLocation, FrameGeneration ? 1.0f : 0.0f);
            if (_frameBlendAmountLocation >= 0) _gl.Uniform1(_frameBlendAmountLocation, Math.Clamp(FrameBlendAmount, 0.0f, 0.5f));

            _gl.ActiveTexture(TextureUnit.Texture1);
            _gl.BindTexture(TextureTarget.Texture2D, _previousTexture);
            _gl.ActiveTexture(TextureUnit.Texture0);

            _gl.BindVertexArray(_vao);
            _gl.DrawElements(PrimitiveType.Triangles, (uint)Indices.Length, DrawElementsType.UnsignedInt, null);

            if (FrameGeneration)
            {
                Array.Copy(frameBuffer, _previousFrameBuffer, _previousFrameBuffer.Length);
                _hasPreviousFrame = true;
            }
            else
            {
                _hasPreviousFrame = false;
            }
        }

        private uint CreateShaderProgram(string vertexSource, string fragmentSource)
        {
            uint vertexShader = CompileShader(ShaderType.VertexShader, vertexSource);
            uint fragmentShader = CompileShader(ShaderType.FragmentShader, fragmentSource);
            uint program = _gl.CreateProgram();
            _gl.AttachShader(program, vertexShader);
            _gl.AttachShader(program, fragmentShader);
            _gl.LinkProgram(program);

            _gl.GetProgram(program, GLEnum.LinkStatus, out var status);
            if (status == 0)
            {
                string infoLog = _gl.GetProgramInfoLog(program);
                _gl.DeleteProgram(program);
                _gl.DeleteShader(vertexShader);
                _gl.DeleteShader(fragmentShader);
                throw new Exception($"Error linking shader program: {infoLog}");
            }

            _gl.DeleteShader(vertexShader);
            _gl.DeleteShader(fragmentShader);
            return program;
        }

        private uint CompileShader(ShaderType type, string source)
        {
            uint shader = _gl.CreateShader(type);
            _gl.ShaderSource(shader, source);
            _gl.CompileShader(shader);
            _gl.GetShader(shader, GLEnum.CompileStatus, out var status);
            string infoLog = _gl.GetShaderInfoLog(shader);
            if (status == 0)
            {
                _gl.DeleteShader(shader);
                throw new Exception($"Error compiling {type}: {infoLog}");
            }
            if (!string.IsNullOrWhiteSpace(infoLog))
                Serilog.Log.Warning("OpenGL {ShaderType} shader compiler reported: {InfoLog}", type, infoLog);
            return shader;
        }

        public void Dispose()
        {
            if (_texture != 0) _gl.DeleteTexture(_texture);
            if (_previousTexture != 0) _gl.DeleteTexture(_previousTexture);
            if (_shaderProgram != 0) _gl.DeleteProgram(_shaderProgram);
            if (_vao != 0) _gl.DeleteVertexArray(_vao);
            if (_vbo != 0) _gl.DeleteBuffer(_vbo);
            if (_ebo != 0) _gl.DeleteBuffer(_ebo);
        }
    }
}
'@
[System.IO.File]::WriteAllText($rendererPath, $renderer, [System.Text.UTF8Encoding]::new($false))

$fragmentShader = @'
#version 330 core
out vec4 FragColor;
in vec2 TexCoord;
uniform sampler2D ourTexture;
uniform sampler2D uPreviousTexture;
uniform float uScanlineStrength;
uniform float uLcdGridStrength;
uniform float uCrtStrength;
uniform float uBrightness;
uniform float uSaturation;
uniform int uUpscaleMode;
uniform float uFrameBlend;
uniform float uFrameBlendAmount;

void main()
{
    vec2 uv = TexCoord;

    if (uCrtStrength > 0.0)
    {
        vec2 curved = uv * 2.0 - 1.0;
        float radius = dot(curved, curved);
        curved *= 1.0 + 0.035 * uCrtStrength * radius;
        uv = curved * 0.5 + 0.5;
    }

    float inside = step(0.0, uv.x) * step(0.0, uv.y) * step(uv.x, 1.0) * step(uv.y, 1.0);
    vec2 textureSizePx = vec2(textureSize(ourTexture, 0));

    if (uUpscaleMode == 2)
    {
        vec2 pixel = uv * textureSizePx;
        vec2 fraction = fract(pixel);
        vec2 centre = floor(pixel) + vec2(0.5);
        vec2 sharpened = centre + clamp((fraction - vec2(0.5)) * 1.45, vec2(-0.5), vec2(0.5));
        uv = sharpened / textureSizePx;
    }

    vec4 color = texture(ourTexture, uv);

    if (uFrameBlend > 0.5)
    {
        vec4 previous = texture(uPreviousTexture, uv);
        color = mix(color, previous, clamp(uFrameBlendAmount, 0.0, 0.5));
    }

    if (uScanlineStrength > 0.0)
    {
        float line = floor(TexCoord.y * 144.0);
        if (mod(line, 2.0) >= 1.0)
            color.rgb *= (1.0 - uScanlineStrength);
    }

    if (uLcdGridStrength > 0.0)
    {
        vec2 cell = fract(TexCoord * vec2(160.0, 144.0));
        float edgeDistance = min(min(cell.x, 1.0 - cell.x), min(cell.y, 1.0 - cell.y));
        float gridLine = 1.0 - smoothstep(0.0, 0.075, edgeDistance);
        color.rgb *= 1.0 - gridLine * uLcdGridStrength;
    }

    float luminance = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(vec3(luminance), color.rgb, uSaturation) * uBrightness;

    if (uCrtStrength > 0.0)
    {
        vec2 centred = TexCoord * 2.0 - 1.0;
        float vignette = 1.0 - 0.13 * dot(centred, centred);
        color.rgb *= mix(1.0, vignette, uCrtStrength);
    }

    if (inside < 0.5)
        color = vec4(0.0, 0.0, 0.0, 1.0);

    FragColor = color;
}
'@
[System.IO.File]::WriteAllText($shaderPath, $fragmentShader, [System.Text.UTF8Encoding]::new($false))


# When V-Sync is enabled, let the swap interval pace presentation instead of sleeping a second time.
$programPath = Join-Path $vendor "Program.cs"
if (Test-Path $programPath) {
    $program = [System.IO.File]::ReadAllText($programPath)
    $program = Replace-ExactlyOnce $program '            if (gameWindow.TurboActive)' @'
            if (gameWindow.TurboActive || config.Video.VSync)
'@ "V-Sync frame pacing"
    [System.IO.File]::WriteAllText($programPath, $program, [System.Text.UTF8Encoding]::new($false))
}


# Broaden standard cartridge handling and reject mapper fallbacks that would corrupt gameplay.
$mmuPath = Join-Path $vendor "Core/Mmu.cs"
$headerPath = Join-Path $vendor "Core/RomHeader.cs"
$romRamPath = Join-Path $vendor "Storage/RomRam.cs"
$testsPath = Join-Path $vendor "GameboySharp.Tests/CartridgeCompatibilityTests.cs"

$mmu = [System.IO.File]::ReadAllText($mmuPath)
$mmu = Replace-ExactlyOnce $mmu '        private IMbc CreateMbc(byte cartridgeType, byte[] romData, int ramSize)' '        internal static IMbc CreateMbc(byte cartridgeType, byte[] romData, int ramSize)' "cartridge factory visibility"
$mmu = Replace-ExactlyOnce $mmu @'
                case 0x00: // ROM ONLY
                    return new RomOnly(romData);
'@ @'
                case 0x00: // ROM ONLY
                    return new RomOnly(romData);

                case 0x08: // ROM + RAM (no mapper)
                    return new RomRam(romData, ramSize, hasBattery: false);

                case 0x09: // ROM + RAM + Battery (no mapper)
                    return new RomRam(romData, ramSize, hasBattery: true);
'@ "ROM+RAM cartridge types"
$mmu = Replace-ExactlyOnce $mmu @'
                default:
                    Log.Warning($"Unsupported cartridge type 0x{cartridgeType:X2}, falling back to ROM-only");
                    return new RomOnly(romData);
'@ @'
                default:
                    throw new NotSupportedException(
                        $"Unsupported Game Boy cartridge mapper 0x{cartridgeType:X2}. " +
                        "PocketGB will not silently emulate this cartridge as ROM-only because banking and saves would be incorrect.");
'@ "unsupported mapper handling"
[System.IO.File]::WriteAllText($mmuPath, $mmu, [System.Text.UTF8Encoding]::new($false))

$header = [System.IO.File]::ReadAllText($headerPath)
$header = Replace-ExactlyOnce $header '                RomSize = 32 * 1024 << romData[0x0148],' '                RomSize = DecodeRomSize(romData[0x0148]),' "ROM size decoding"
$header = Replace-ExactlyOnce $header '        public static RomHeader Parse(byte[] romData)' @'
        private static int DecodeRomSize(byte sizeCode)
        {
            if (sizeCode <= 0x08)
                return checked(32 * 1024 * (1 << sizeCode));

            // Three valid non-power-of-two ROM sizes defined by the Game Boy cartridge header.
            return sizeCode switch
            {
                0x52 => 72 * 0x4000, // 1.125 MiB
                0x53 => 80 * 0x4000, // 1.25 MiB
                0x54 => 96 * 0x4000, // 1.5 MiB
                _ => throw new InvalidDataException($"Invalid Game Boy ROM size code 0x{sizeCode:X2}.")
            };
        }

        public static RomHeader Parse(byte[] romData)
'@ "special ROM size code helper"
[System.IO.File]::WriteAllText($headerPath, $header, [System.Text.UTF8Encoding]::new($false))

$romRam = @'
using System.IO;

namespace GameboySharp
{
    /// <summary>
    /// ROM+RAM cartridge without a memory bank controller (cartridge types 0x08/0x09).
    /// The small external RAM window mirrors when the cartridge contains 2 KiB.
    /// </summary>
    public sealed class RomRam : IMbc
    {
        private readonly byte[] _romData;
        private readonly byte[] _ramData;
        private readonly bool _hasBattery;

        public bool IsRamEnabled => _ramData.Length > 0;
        public int CurrentRomBank => 1;
        public int CurrentRamBank => 0;
        public bool HasBattery => _hasBattery;

        public RomRam(byte[] romData, int ramSize, bool hasBattery)
        {
            _romData = romData ?? throw new ArgumentNullException(nameof(romData));
            if (_romData.Length > 0x8000)
                throw new NotSupportedException("ROM+RAM cartridges without a mapper cannot address ROM larger than 32 KiB.");
            if (ramSize < 0 || ramSize > 0x2000)
                throw new ArgumentOutOfRangeException(nameof(ramSize), "ROM+RAM cartridges support up to 8 KiB of external RAM.");

            _ramData = new byte[ramSize];
            Array.Fill(_ramData, (byte)0xFF);
            _hasBattery = hasBattery;
        }

        public byte ReadRom(ushort address) =>
            address < 0x8000 && address < _romData.Length ? _romData[address] : (byte)0xFF;

        public void WriteRom(ushort address, byte value) { }

        public byte ReadRam(ushort address)
        {
            if (_ramData.Length == 0 || address < 0xA000 || address >= 0xC000) return 0xFF;
            int index = (address - 0xA000) % _ramData.Length;
            return _ramData[index];
        }

        public void WriteRam(ushort address, byte value)
        {
            if (_ramData.Length == 0 || address < 0xA000 || address >= 0xC000) return;
            int index = (address - 0xA000) % _ramData.Length;
            _ramData[index] = value;
        }

        public byte[] GetRam() => _ramData;

        public void SetRam(byte[] data)
        {
            if (data == null || _ramData.Length == 0) return;
            Array.Copy(data, _ramData, Math.Min(data.Length, _ramData.Length));
        }

        public void SaveState(BinaryWriter writer)
        {
            writer.Write(_ramData.Length);
            writer.Write(_ramData);
        }

        public void LoadState(BinaryReader reader)
        {
            int length = reader.ReadInt32();
            if (length < 0 || length > 0x2000) throw new InvalidDataException("Invalid ROM+RAM state size.");
            SetRam(reader.ReadBytes(length));
        }
    }
}
'@
[System.IO.File]::WriteAllText($romRamPath, $romRam, [System.Text.UTF8Encoding]::new($false))

$testCode = @'
using GameboySharp;
using Xunit;

namespace GameboySharp.Tests;

public sealed class CartridgeCompatibilityTests
{
    [Theory]
    [InlineData(0x52, 72 * 0x4000)]
    [InlineData(0x53, 80 * 0x4000)]
    [InlineData(0x54, 96 * 0x4000)]
    [InlineData(0x08, 8 * 1024 * 1024)]
    public void ParsesStandardAndSpecialRomSizes(byte sizeCode, int expectedBytes)
    {
        byte[] rom = new byte[0x150];
        rom[0x148] = sizeCode;
        RomHeader header = RomHeader.Parse(rom);
        Assert.Equal(expectedBytes, header.RomSize);
    }

    [Fact]
    public void SupportsRomPlusRamCartridgeAndMirrorsTwoKilobyteRam()
    {
        byte[] rom = new byte[0x8000];
        IMbc mbc = Mmu.CreateMbc(0x08, rom, 0x800);
        Assert.False(mbc.HasBattery);
        Assert.Equal(0x800, mbc.GetRam().Length);
        mbc.WriteRam(0xA000, 0x42);
        Assert.Equal(0x42, mbc.ReadRam(0xA800));
    }

    [Fact]
    public void RomPlusRamBatteryVariantPersistsBatteryFlag()
    {
        IMbc mbc = Mmu.CreateMbc(0x09, new byte[0x8000], 0x2000);
        Assert.True(mbc.HasBattery);
    }

    [Fact]
    public void UnsupportedMapperIsReportedInsteadOfSilentlyFallingBackToRomOnly()
    {
        var exception = Assert.Throws<NotSupportedException>(
            () => Mmu.CreateMbc(0x22, new byte[0x8000], 0x2000));
        Assert.Contains("0x22", exception.Message);
    }

    [Fact]
    public void RejectsInvalidRomSizeHeaderCode()
    {
        byte[] rom = new byte[0x150];
        rom[0x148] = 0x55;
        Assert.Throws<InvalidDataException>(() => RomHeader.Parse(rom));
    }
}
'@
$testsDirectory = Split-Path -Parent $testsPath
New-Item -ItemType Directory -Force $testsDirectory | Out-Null
[System.IO.File]::WriteAllText($testsPath, $testCode, [System.Text.UTF8Encoding]::new($false))

Write-Host "PocketGB display controls, shader filters, temporal blending and GPU diagnostics prepared." -ForegroundColor Green


# CGB startup correctness and double-speed timer regression fixes.
# The prior implementation used the DMG-compatibility CGB register values for all CGB games,
# and selected bank 1/7 instead of the post-boot VRAM bank 0 / WRAM bank 1.
$cpuPath = Join-Path $vendor "Core/Cpu.cs"
$cpuSource = [System.IO.File]::ReadAllText($cpuPath)
$cpuSource = Replace-ExactlyOnce $cpuSource '            DE = 0x0008;  // D=0x00, E=0x08 - GBC specific  ' '            DE = 0xFF56;  // CGB boot-ROM post-boot value' "CGB DE boot register"
$cpuSource = Replace-ExactlyOnce $cpuSource '            HL = 0x007C;  // H=0x00, L=0x7C - GBC specific' '            HL = 0x000D;  // CGB boot-ROM post-boot value' "CGB HL boot register"
[System.IO.File]::WriteAllText($cpuPath, $cpuSource, [System.Text.UTF8Encoding]::new($false))

$emulatorPath = Join-Path $vendor "Emulator.cs"
$emulatorSource = [System.IO.File]::ReadAllText($emulatorPath)
$emulatorSource = Replace-ExactlyOnce $emulatorSource '            Mmu.WriteByte(IORegisters.VBK, 0xFF);  // VRAM Bank Select - Bank 0' '            Mmu.WriteByte(IORegisters.VBK, 0xFE);  // CGB post-boot VBK: bank 0' "CGB VRAM bank default"
$emulatorSource = Replace-ExactlyOnce $emulatorSource '            Mmu.WriteByte(IORegisters.SVBK, 0xFF); // WRAM Bank Select - Bank 1' '            Mmu.WriteByte(IORegisters.SVBK, 0xF8); // CGB post-boot SVBK: bank 1' "CGB WRAM bank default"

# PPU/APU run in Game Boy dots and keep normal speed in CGB double-speed mode.
# DIV/TIMA follow the CPU clock and therefore must receive the full instruction cycle count.
$emulatorSource = Replace-ExactlyOnce $emulatorSource @'
                Ppu.Step(machineCycles);
                Timer.Tick(machineCycles);
                Apu.Step(machineCycles);
'@ @'
                Ppu.Step(machineCycles);
                Timer.Tick(cycles); // DIV/TIMA double with the CGB CPU clock; PPU/APU do not.
                Apu.Step(machineCycles);
'@ "CGB double-speed timer clock"
[System.IO.File]::WriteAllText($emulatorPath, $emulatorSource, [System.Text.UTF8Encoding]::new($false))

# Focused regressions: CGB post-boot state and doubled divider timing.
$regressionTestsPath = Join-Path $vendor "GameboySharp.Tests/CgbStartupRegressionTests.cs"
$regressionTests = @'
using System;
using System.IO;
using Xunit;

namespace GameboySharp.Tests;

public sealed class CgbStartupRegressionTests
{
    private static string CreateTemporaryCgbRom()
    {
        byte[] rom = new byte[32 * 1024];
        rom[0x0134] = 0x54;
        rom[0x0135] = 0x45;
        rom[0x0136] = 0x53;
        rom[0x0137] = 0x54;
        rom[0x0143] = 0x80; // CGB-compatible cartridge
        rom[0x0147] = 0x00; // ROM-only cartridge
        rom[0x0148] = 0x00; // 32 KiB ROM
        rom[0x0149] = 0x00; // No external RAM

        string path = Path.Combine(Path.GetTempPath(), $"pocketgb-cgb-{Guid.NewGuid():N}.gbc");
        File.WriteAllBytes(path, rom);
        return path;
    }

    [Fact]
    public void CgbCartridgeStartsWithDocumentedCpuAndMemoryBankState()
    {
        Environment.SetEnvironmentVariable("GBSHARP_AUDIO", "none");
        string path = CreateTemporaryCgbRom();

        try
        {
            using var emulator = new Emulator();
            emulator.LoadRom(path);

            Assert.True(emulator.Mmu.IsGameBoyColor);
            Assert.Equal((ushort)0x1180, emulator.Cpu.AF);
            Assert.Equal((ushort)0x0000, emulator.Cpu.BC);
            Assert.Equal((ushort)0xFF56, emulator.Cpu.DE);
            Assert.Equal((ushort)0x000D, emulator.Cpu.HL);
            Assert.Equal(0, emulator.Mmu.CurrentVramBank);
            Assert.Equal(1, emulator.Mmu.CurrentWramBank);
            Assert.Equal((byte)0xFE, emulator.Mmu.ReadByte(0xFF4F));
            Assert.Equal((byte)0xF8, emulator.Mmu.ReadByte(0xFF70));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void CgbDoubleSpeedAdvancesDividerAtTwiceTheDotClockRate()
    {
        Environment.SetEnvironmentVariable("GBSHARP_AUDIO", "none");
        string path = CreateTemporaryCgbRom();

        try
        {
            using var emulator = new Emulator();
            emulator.LoadRom(path);

            emulator.Mmu.WriteByte(0xFF4D, 0x01);
            emulator.Mmu.PerformSpeedSwitch();
            Assert.True(emulator.Mmu.IsDoubleSpeedMode);

            // One emulated frame is 70,224 PPU dots. In CGB double-speed mode the CPU
            // executes 140,448 T-cycles, so DIV increments 548 times (low byte = 0x24).
            emulator.RunFrame();

            Assert.Equal((byte)0x24, emulator.Timer.ReadDIV());
        }
        finally
        {
            File.Delete(path);
        }
    }
}
'@
$testDirectory = Split-Path -Parent $regressionTestsPath
New-Item -ItemType Directory -Force $testDirectory | Out-Null
[System.IO.File]::WriteAllText($regressionTestsPath, $regressionTests, [System.Text.UTF8Encoding]::new($false))


# Preserve the SVBK register's written value separately from the physical bank mapping.
# On hardware, writing 0 maps bank 1 but reads back as 0 (F8 with upper bits set).
$mmuPath = Join-Path $vendor "Core/Mmu.cs"
$mmuSource = [System.IO.File]::ReadAllText($mmuPath)
$mmuSource = Replace-ExactlyOnce $mmuSource '        private byte _wramBank = 1; // Current WRAM bank (1-7, bank 0 is fixed)' @'
        private byte _wramBank = 0; // SVBK register bits; zero maps physical WRAM bank 1
        private byte EffectiveWramBank => _wramBank == 0 ? (byte)1 : _wramBank;
'@ "SVBK register storage"
$mmuSource = Replace-ExactlyOnce $mmuSource '        public byte CurrentWramBank => _wramBank;' '        public byte CurrentWramBank => EffectiveWramBank;' "effective WRAM bank diagnostic"
$bankIndexCount = ([regex]::Matches($mmuSource, [regex]::Escape('int bankIndex = _wramBank;'))).Count
if ($bankIndexCount -ne 2) { throw "Expected exactly two WRAM bank access sites, found $bankIndexCount." }
$mmuSource = $mmuSource.Replace('int bankIndex = _wramBank;', 'int bankIndex = EffectiveWramBank;')
$mmuSource = Replace-ExactlyOnce $mmuSource '            _wramBank = 1;' '            _wramBank = 0;' "SVBK reset register value"
$mmuSource = Replace-ExactlyOnce $mmuSource '                        byte newBank = (byte)(value & 0x07); // Only bits 0-2 are used' '                        _wramBank = (byte)(value & 0x07); // Preserve register value; zero maps to physical bank 1' "SVBK register write"
$mmuSource = Replace-ExactlyOnce $mmuSource '                        if (newBank == 0) newBank = 1; // Bank 0 is not accessible, use bank 1 instead' '' "SVBK bank-zero remapping"
$mmuSource = Replace-ExactlyOnce $mmuSource '                        _wramBank = newBank;' '' "SVBK effective bank assignment removal"
$mmuSource = Replace-ExactlyOnce $mmuSource '                        Log.Debug($"WRAM bank switched to: {_wramBank}");' '                        Log.Debug($"WRAM bank register set to: {_wramBank}; physical bank: {EffectiveWramBank}");' "SVBK bank diagnostic"
[System.IO.File]::WriteAllText($mmuPath, $mmuSource, [System.Text.UTF8Encoding]::new($false))

Write-Host "CGB post-boot registers, bank defaults and double-speed timer clock patched with regression tests." -ForegroundColor Green
