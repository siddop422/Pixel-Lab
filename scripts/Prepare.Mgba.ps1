$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$vendor = Join-Path $root "vendor/GameboySharp"

function Replace-ExactlyOnce([string]$Source, [string]$Old, [string]$New, [string]$Label) {
    $count = ([regex]::Matches($Source, [regex]::Escape($Old))).Count
    if ($count -ne 1) { throw "Expected one $Label anchor, found $count." }
    return $Source.Replace($Old, $New)
}

# Share the existing SDL/OpenAL audio factory with the mGBA adapter.
$emulatorPath = Join-Path $vendor "Emulator.cs"
$emulator = [System.IO.File]::ReadAllText($emulatorPath)
$emulator = Replace-ExactlyOnce $emulator '        private static IAudioSink CreateAudioSink(AudioBackend backend)' '        internal static IAudioSink CreateAudioSink(AudioBackend backend)' "shared audio factory"
[System.IO.File]::WriteAllText($emulatorPath, $emulator, [System.Text.UTF8Encoding]::new($false))

# Add a length-aware fast path to avoid allocating slices of audio arrays every frame.
$sdlPath = Join-Path $vendor "Sound/SdlAudioSink.cs"
$sdl = [System.IO.File]::ReadAllText($sdlPath)
$sdl = Replace-ExactlyOnce $sdl '    internal unsafe class SdlAudioSink : IAudioSink' '    internal unsafe class SdlAudioSink : IAudioSink, IAudioSinkWithCount' "SDL audio interface"
$oldSdl = @'
        public void Submit(short[] left, short[] right)
        {
            // If SDL still has plenty buffered, skip this block rather than pile on latency.
            if (SDL_GetAudioStreamQueued(_stream) > _maxQueuedBytes) return;

            int frames = left.Length;
            int needed = frames * Channels;
            if (_interleaved.Length < needed) _interleaved = new short[needed];

            for (int i = 0; i < frames; i++)
            {
                _interleaved[i * 2] = left[i];
                _interleaved[i * 2 + 1] = right[i];
            }

            fixed (short* ptr = _interleaved)
            {
                SDL_PutAudioStreamData(_stream, (IntPtr)ptr, needed * sizeof(short));
            }
        }
'@
$newSdl = @'
        public void Submit(short[] left, short[] right) => Submit(left, right, Math.Min(left.Length, right.Length));

        public void Submit(short[] left, short[] right, int frames)
        {
            frames = Math.Clamp(frames, 0, Math.Min(left.Length, right.Length));
            if (frames == 0 || SDL_GetAudioStreamQueued(_stream) > _maxQueuedBytes) return;

            int needed = frames * Channels;
            if (_interleaved.Length < needed) _interleaved = new short[needed];
            for (int i = 0; i < frames; i++)
            {
                _interleaved[i * 2] = left[i];
                _interleaved[i * 2 + 1] = right[i];
            }

            fixed (short* ptr = _interleaved)
                SDL_PutAudioStreamData(_stream, (IntPtr)ptr, needed * sizeof(short));
        }
'@
$sdl = Replace-ExactlyOnce $sdl $oldSdl $newSdl "SDL audio submit methods"
[System.IO.File]::WriteAllText($sdlPath, $sdl, [System.Text.UTF8Encoding]::new($false))

$alPath = Join-Path $vendor "Sound/AudioStreamerAL.cs"
$al = [System.IO.File]::ReadAllText($alPath)
$al = Replace-ExactlyOnce $al '    public unsafe class AudioStreamerAL : IAudioSink' '    public unsafe class AudioStreamerAL : IAudioSink, IAudioSinkWithCount' "OpenAL audio interface"
$oldAl = @'
        public void Submit(short[] left, short[] right)
        {
            // Drop the oldest audio if the queue is backing up, so latency can't grow unbounded.
            while (_audioQueue.Count > MAX_QUEUE_SIZE) _audioQueue.TryDequeue(out _);

            for (int i = 0; i < left.Length; i++)
            {
                _audioQueue.Enqueue(left[i]);
                _audioQueue.Enqueue(right[i]);
            }
        }
'@
$newAl = @'
        public void Submit(short[] left, short[] right) => Submit(left, right, Math.Min(left.Length, right.Length));

        public void Submit(short[] left, short[] right, int frames)
        {
            frames = Math.Clamp(frames, 0, Math.Min(left.Length, right.Length));
            if (frames == 0) return;
            while (_audioQueue.Count > MAX_QUEUE_SIZE) _audioQueue.TryDequeue(out _);
            for (int i = 0; i < frames; i++)
            {
                _audioQueue.Enqueue(left[i]);
                _audioQueue.Enqueue(right[i]);
            }
        }
'@
$al = Replace-ExactlyOnce $al $oldAl $newAl "OpenAL audio submit methods"
[System.IO.File]::WriteAllText($alPath, $al, [System.Text.UTF8Encoding]::new($false))

# Add the selectable emulation core preference.
$configPath = Join-Path $vendor "Config/EmulatorConfig.cs"
$config = [System.IO.File]::ReadAllText($configPath)
$config = Replace-ExactlyOnce $config '    public class EmulatorConfig' @'
    public enum EmulationBackend
    {
        Auto,
        GameboySharp,
        Mgba
    }

    public class EmulatorConfig
'@ "emulation backend enum"
$config = Replace-ExactlyOnce $config '        public double TurboSpeedMultiplier { get; set; } = 4.0;' @'
        public double TurboSpeedMultiplier { get; set; } = 4.0;
        public EmulationBackend EmulationBackend { get; set; } = EmulationBackend.Auto;
'@ "emulation backend setting"
[System.IO.File]::WriteAllText($configPath, $config, [System.Text.UTF8Encoding]::new($false))

# Expose the true core choice in Settings > General.
$settingsPath = Join-Path $vendor "UI/SettingsDialog.cs"
$settings = [System.IO.File]::ReadAllText($settingsPath)
$settings = Replace-ExactlyOnce $settings @'
            if (ImGui.Combo("Turbo speed while holding Tab", ref turboIndex, turboLabels, turboLabels.Length))
                _config.General.TurboSpeedMultiplier = turboValues[turboIndex];

            string saveDir = _config.General.SaveDirectory;
'@ @'
            if (ImGui.Combo("Turbo speed while holding Tab", ref turboIndex, turboLabels, turboLabels.Length))
                _config.General.TurboSpeedMultiplier = turboValues[turboIndex];

            ImGui.SeparatorText("Emulation core");
            string[] coreNames = { "Auto (recommended)", "GameboySharp (GB/GBC)", "mGBA (GB/GBC/GBA)" };
            int coreIndex = (int)_config.General.EmulationBackend;
            if (ImGui.Combo("Emulation backend", ref coreIndex, coreNames, coreNames.Length))
                _config.General.EmulationBackend = (EmulationBackend)coreIndex;
            ImGui.TextDisabled("Auto prefers mGBA for GB/GBC/GBA compatibility. GameboySharp remains available as a manual GB/GBC fallback.");

            string saveDir = _config.General.SaveDirectory;
'@ "core selection UI"
[System.IO.File]::WriteAllText($settingsPath, $settings, [System.Text.UTF8Encoding]::new($false))

Write-Host "mGBA audio sharing and core selection prepared." -ForegroundColor Green


# Let the ROM loader extract GBA ROMs from ZIP files as well as GB/GBC ROMs.
$romLoaderPath = Join-Path $vendor "RomFileLoader.cs"
$romLoader = [System.IO.File]::ReadAllText($romLoaderPath)
$romLoader = Replace-ExactlyOnce $romLoader '        private static readonly string[] RomExtensions = { ".gb", ".gbc", ".sgb" };' '        private static readonly string[] RomExtensions = { ".gb", ".gbc", ".sgb", ".gba" };' "mGBA ROM extension list"
$oldGbaReject = @'
            if (extension.Equals(".gba", StringComparison.OrdinalIgnoreCase))
            {
                throw new NotSupportedException(
                    "This is a Game Boy Advance ROM. The current PocketGB core only emulates Game Boy and Game Boy Color; a separate GBA core such as mGBA is required. The ROM file has not been modified.");
            }

'@
if ($romLoader.Contains($oldGbaReject)) {
    $romLoader = $romLoader.Replace($oldGbaReject, "")
}
[System.IO.File]::WriteAllText($romLoaderPath, $romLoader, [System.Text.UTF8Encoding]::new($false))

# Add a routing callback to GameWindow and choose the correct core based on the resolved cartridge type.
$windowPath = Join-Path $vendor "UI/GameWindow.cs"
$window = [System.IO.File]::ReadAllText($windowPath)
$window = Replace-ExactlyOnce $window '        private readonly Toolbar _toolbar;' @'
        private readonly Toolbar _toolbar;
        public Action<string>? OpenMgbaGameRequested { get; set; }
        private string _runtimeError = "";
        public bool HasRuntimeError => !string.IsNullOrWhiteSpace(_runtimeError);
'@ "mGBA game routing callback"

$window = Replace-ExactlyOnce $window '            _config = config;' @'
            _config = config;
            _runtimeError = CrashReporter.GetRecentCrashNotice() ?? "";
'@ "previous crash notice in GB window"

$loadStart = $window.IndexOf("        private void LoadRomFromUi(string path)")
$loadEnd = $window.IndexOf("        /// <summary>Tracks a smoothed FPS", $loadStart)
if ($loadStart -lt 0 -or $loadEnd -lt 0 -or $loadEnd -le $loadStart) {
    throw "Could not locate GameWindow.LoadRomFromUi."
}
$newLoadMethod = @'
        private void LoadRomFromUi(string path)
        {
            try
            {
                string resolvedPath = RomFileLoader.ResolveRomPath(path);
                string extension = Path.GetExtension(resolvedPath);
                bool isLegacyGbExtension = extension.Equals(".gb", StringComparison.OrdinalIgnoreCase) ||
                    extension.Equals(".gbc", StringComparison.OrdinalIgnoreCase) ||
                    extension.Equals(".sgb", StringComparison.OrdinalIgnoreCase);
                bool requiresMgba = !isLegacyGbExtension ||
                    _config.General.EmulationBackend != EmulationBackend.GameboySharp;

                if (requiresMgba)
                {
                    if (OpenMgbaGameRequested == null)
                        throw new InvalidOperationException("The mGBA window is not available in this build.");
                    _runtimeError = "";
                    OpenMgbaGameRequested(path);
                    return;
                }

                _emulator.LoadRom(resolvedPath, path);
                _runtimeError = "";
                _config.AddRecentRom(path);
                ConfigStore.Save(_config);
                Log.Information("Loaded ROM with GameboySharp: {Path}", path);
            }
            catch (Exception ex)
            {
                _emulator.Cpu.Pause();
                _runtimeError = CrashReporter.WriteException("Load Game Boy cartridge", path, ex);
                Log.Error(ex, "Failed to load ROM: {Path}", path);
            }
        }

'@
$window = $window.Substring(0, $loadStart) + $newLoadMethod + $window.Substring($loadEnd)

$resetModalAnchor = @'
                if (ImGui.Button("Reset", new Vector2(120, 0)))
                {
                    _emulator.Reset();
                    ImGui.CloseCurrentPopup();
                }
'@
$resetModalReplacement = @'
                if (ImGui.Button("Reset", new Vector2(120, 0)))
                {
                    try
                    {
                        _emulator.Reset();
                        _runtimeError = "";
                    }
                    catch (Exception ex)
                    {
                        _runtimeError = CrashReporter.WriteException("Reset Game Boy cartridge", _emulator.CurrentRomName, ex);
                    }
                    ImGui.CloseCurrentPopup();
                }
'@
$window = Replace-ExactlyOnce $window $resetModalAnchor $resetModalReplacement "recoverable Game Boy reset action"

$reportMethod = @'
        public void ReportRuntimeError(Exception exception)
        {
            _emulator.Cpu.Pause();
            _turboActive = false;
            _runtimeError = CrashReporter.WriteException(
                "Run Game Boy emulation frame", _emulator.CurrentRomName, exception);
            Log.Error(exception, "PocketGB stopped Game Boy emulation after a recoverable error.");
        }

'@
$window = Replace-ExactlyOnce $window '        private void OnLoad()' ($reportMethod + '        private void OnLoad()') "runtime error reporting method"

$drawAnchor = @'
            _settingsDialog.Draw();
            DrawResetConfirm();
'@
$drawReplacement = @'
            _settingsDialog.Draw();
            DrawResetConfirm();
            DrawRuntimeError();
'@
$window = Replace-ExactlyOnce $window $drawAnchor $drawReplacement "runtime error panel call"

$runtimeErrorUi = @'
        private void DrawRuntimeError()
        {
            if (string.IsNullOrWhiteSpace(_runtimeError)) return;
            var viewport = ImGui.GetMainViewport();
            ImGui.SetNextWindowPos(viewport.Pos + new Vector2(16f, Toolbar.HeightPoints + 12f), ImGuiCond.Always);
            ImGui.SetNextWindowBgAlpha(0.94f);
            if (ImGui.Begin("PocketGB paused after an error", ImGuiWindowFlags.AlwaysAutoResize | ImGuiWindowFlags.NoCollapse))
            {
                ImGui.TextWrapped(_runtimeError);
                if (ImGui.Button("Copy error report"))
                    ImGui.SetClipboardText(CrashReporter.BuildClipboardText(_runtimeError));
                ImGui.SameLine();
                if (ImGui.Button("Dismiss")) _runtimeError = "";
                ImGui.TextDisabled("The emulator is paused. Open another game to continue.");
            }
            ImGui.End();
        }

'@
$window = Replace-ExactlyOnce $window '        private void ComputeGameViewport(' ($runtimeErrorUi + '        private void ComputeGameViewport(') "runtime error panel method"
[System.IO.File]::WriteAllText($windowPath, $window, [System.Text.UTF8Encoding]::new($false))

# Include the managed adapters and built native DLL in the Windows app publish directory.
$projectPath = Join-Path $vendor "GameboySharp.csproj"
$project = [System.IO.File]::ReadAllText($projectPath)

# Set the desktop executable name in this project only. Passing AssemblyName as a global
# publish property also renames referenced projects, which makes NuGet restore ambiguous
# once the shared PocketGB.Shared project is added.
if (-not $project.Contains("<AssemblyName>")) {
    $assemblyItem = @'
  <PropertyGroup>
    <AssemblyName>PocketGB</AssemblyName>
  </PropertyGroup>
'@
    $project = $project.Replace("</Project>", $assemblyItem + [Environment]::NewLine + "</Project>")
}

if (-not $project.Contains("native/mgba/managed/*.cs")) {
    $items = @'
  <ItemGroup>
    <Compile Include="../../native/mgba/managed/*.cs" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="../../shared/PocketGB.Shared.csproj" />
  </ItemGroup>

  <ItemGroup Condition="'$(RuntimeIdentifier)' == 'win-x64'">
    <Content Include="../../artifacts/native/win-x64/**/*">
      <Link>%(RecursiveDir)%(Filename)%(Extension)</Link>
      <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
      <CopyToPublishDirectory>PreserveNewest</CopyToPublishDirectory>
    </Content>
  </ItemGroup>
'@
    $project = $project.Replace("</Project>", $items + [Environment]::NewLine + "</Project>")
}
[System.IO.File]::WriteAllText($projectPath, $project, [System.Text.UTF8Encoding]::new($false))

Write-Host "GBA ROM loading, core routing and native publish assets prepared." -ForegroundColor Green


# Route command-line .gba files to mGBA instead of asking the Game Boy-only core to parse them.
$programPath = Join-Path $vendor "Program.cs"
$program = [System.IO.File]::ReadAllText($programPath)
$startupStart = $program.IndexOf("        if (args.Length > 0)")
$startupEnd = $program.IndexOf('        Log.Information("Creating windows...");', $startupStart)
if ($startupStart -lt 0 -or $startupEnd -lt 0 -or $startupEnd -le $startupStart) {
    throw "Could not find Program.cs startup game-loading block."
}
$startupBlock = @'
        string? mgbaStartupRom = null;
        if (args.Length > 0)
        {
            try
            {
                string resolvedPath = RomFileLoader.ResolveRomPath(args[0]);
                string startupExtension = Path.GetExtension(resolvedPath);
                bool isLegacyGbExtension = startupExtension.Equals(".gb", StringComparison.OrdinalIgnoreCase) ||
                    startupExtension.Equals(".gbc", StringComparison.OrdinalIgnoreCase) ||
                    startupExtension.Equals(".sgb", StringComparison.OrdinalIgnoreCase);
                bool useMgba = !isLegacyGbExtension ||
                    config.General.EmulationBackend != EmulationBackend.GameboySharp;
                if (useMgba) mgbaStartupRom = args[0];
                else emulator.LoadRom(resolvedPath, args[0]);
                config.AddRecentRom(args[0]);
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Failed to load game file at '{Path}'. Open another game from the toolbar.", args[0]);
                CrashReporter.WriteException("Load startup cartridge", args[0], ex);
            }
        }

'@
$program = $program.Substring(0, $startupStart) + $startupBlock + $program.Substring($startupEnd)

# Create the optional mGBA window lazily. Closing it returns to the existing GameboySharp window.
$windowAnchor = @'
        using var gameWindow = new GameWindow(emulator, config);
        using var debugWindow = new DebugWindow(emulator);

'@
$windowReplacement = @'
        using var gameWindow = new GameWindow(emulator, config);
        using var debugWindow = new DebugWindow(emulator);
        MgbaWindow? mgbaWindow = null;
        var framePacer = new EmulationFramePacer();
        bool shuttingDown = false;

        void ReturnToGameboySharp()
        {
            if (shuttingDown) return;
            framePacer.Reset();
            gameWindow.SilkWindow.IsVisible = true;
            debugWindow.SilkWindow.IsVisible = false;
        }

        void OpenMgbaGame(string path)
        {
            try
            {
                if (mgbaWindow == null || mgbaWindow.IsClosing)
                {
                    mgbaWindow?.Dispose();
                    mgbaWindow = new MgbaWindow(config, ReturnToGameboySharp);
                }

                mgbaWindow.LoadRom(path);
                framePacer.Reset();
                gameWindow.SilkWindow.IsVisible = false;
                debugWindow.SilkWindow.IsVisible = false;
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Could not open the mGBA backend for {Path}", path);
                CrashReporter.WriteException("Open mGBA backend", path, ex);
                ReturnToGameboySharp();
            }
        }

        gameWindow.OpenMgbaGameRequested = OpenMgbaGame;
        if (mgbaStartupRom != null) OpenMgbaGame(mgbaStartupRom);

'@
$program = Replace-ExactlyOnce $program $windowAnchor $windowReplacement "mGBA window initialization"

$oldShutdown = @'
        bool shuttingDown = false;
        void ShutDownBothWindows()
        {
            if (shuttingDown) return;
            shuttingDown = true;
            gameWindow.SilkWindow.Close();
            debugWindow.SilkWindow.Close();
        }
'@
$newShutdown = @'
        void ShutDownBothWindows()
        {
            if (shuttingDown) return;
            shuttingDown = true;
            if (mgbaWindow != null && !mgbaWindow.IsClosing)
                mgbaWindow.SilkWindow.Close();
            gameWindow.SilkWindow.Close();
            debugWindow.SilkWindow.Close();
        }
'@
$program = Replace-ExactlyOnce $program $oldShutdown $newShutdown "mGBA shutdown callback"

# One scheduler services either core, using that core's native frame rate and pause state.
$loopStart = $program.IndexOf('        Log.Information("Starting main loop...");')
$loopEnd = $program.IndexOf('        Log.Information("Closing PocketGB.");', $loopStart)
if ($loopStart -lt 0 -or $loopEnd -lt 0 -or $loopEnd -le $loopStart) {
    throw "Could not find Program.cs main-loop boundaries."
}

$loop = @'
        Log.Information("Starting main loop...");
        var frameTimer = Stopwatch.StartNew();
        long previousTimestamp = Stopwatch.GetTimestamp();
        const double presentationFrameMs = 1000.0 / GameboyConstants.FramesPerSecond;
        int turboRenderCounter = 0;

        while (!gameWindow.SilkWindow.IsClosing && !debugWindow.SilkWindow.IsClosing)
        {
            if (mgbaWindow != null && mgbaWindow.IsClosing)
            {
                mgbaWindow.Dispose();
                mgbaWindow = null;
                framePacer.Reset();
            }

            long currentTimestamp = Stopwatch.GetTimestamp();
            double elapsedSeconds = (currentTimestamp - previousTimestamp) / (double)Stopwatch.Frequency;
            previousTimestamp = currentTimestamp;
            frameTimer.Restart();

            gameWindow.SilkWindow.DoEvents();
            debugWindow.SilkWindow.DoEvents();

            bool useMgba = mgbaWindow != null && !mgbaWindow.IsClosing;
            if (useMgba)
            {
                mgbaWindow!.SilkWindow.DoEvents();
                mgbaWindow.SilkWindow.DoUpdate();
            }
            else
            {
                gameWindow.SilkWindow.DoUpdate();
            }

            bool turbo = useMgba ? mgbaWindow!.TurboActive : gameWindow.TurboActive;
            double requestedSpeed = turbo ? config.General.TurboSpeedMultiplier : config.General.SpeedMultiplier;
            double gameFrameRate = useMgba ? mgbaWindow!.NominalFrameRate : GameboyConstants.FramesPerSecond;
            bool paused = useMgba
                ? !mgbaWindow!.HasRom || mgbaWindow.IsPaused
                : !emulator.HasRom || emulator.IsPaused || gameWindow.HasRuntimeError;

            int framesToRun = framePacer.Consume(elapsedSeconds, requestedSpeed, gameFrameRate, paused);

            if (useMgba)
            {
                mgbaWindow!.RunFrames(framesToRun);
                mgbaWindow.RecordEmulatedFrames(framesToRun);
            }
            else if (!gameWindow.HasRuntimeError)
            {
                try
                {
                    emulator.RunFrames(framesToRun);
                    gameWindow.RecordEmulatedFrames(framesToRun);
                }
                catch (Exception ex)
                {
                    // Preserve the window and pause this cartridge instead of exiting the app loop.
                    gameWindow.ReportRuntimeError(ex);
                    framePacer.Reset();
                }
            }

            int renderInterval = turbo ? (requestedSpeed >= 8.0 ? 3 : 2) : 1;
            bool renderNow = !turbo || (++turboRenderCounter % renderInterval == 0);
            if (renderNow)
            {
                if (useMgba)
                    mgbaWindow!.SilkWindow.DoRender();
                else
                {
                    gameWindow.SilkWindow.DoRender();
                    if (debugWindow.SilkWindow.IsVisible)
                        debugWindow.SilkWindow.DoRender();
                }
            }

            if (!turbo && !config.Video.VSync)
            {
                double remainingMs = presentationFrameMs - frameTimer.Elapsed.TotalMilliseconds;
                int sleepMs = (int)Math.Floor(remainingMs);
                if (sleepMs > 0) Thread.Sleep(sleepMs);
                else if (remainingMs > 0) Thread.SpinWait(50);
            }
        }

        mgbaWindow?.Dispose();
'@

$program = $program.Substring(0, $loopStart) + $loop + $program.Substring($loopEnd)
[System.IO.File]::WriteAllText($programPath, $program, [System.Text.UTF8Encoding]::new($false))

Write-Host "mGBA command-line routing and unified GB/GBA frame scheduler prepared." -ForegroundColor Green

# Use one shared extension policy for file browsing, drag/drop and the managed resolver.
$fileBrowserPath = Join-Path $vendor "UI/FileBrowser.cs"
$fileBrowser = [System.IO.File]::ReadAllText($fileBrowserPath)
$fileBrowser = Replace-ExactlyOnce $fileBrowser '        private static readonly string[] RomExtensions = { ".gb", ".gbc", ".sgb", ".zip", ".gba" };' '        private static readonly string[] RomExtensions = { ".gb", ".gbc", ".sgb", ".gba", ".gbx", ".agb", ".dmg", ".cgb", ".bin", ".rom", ".pak", ".zip", ".7z" };' "expanded game file filter"
[System.IO.File]::WriteAllText($fileBrowserPath, $fileBrowser, [System.Text.UTF8Encoding]::new($false))

$windowPath = Join-Path $vendor "UI/GameWindow.cs"
$window = [System.IO.File]::ReadAllText($windowPath)
$window = Replace-ExactlyOnce $window '                if (extension is ".gb" or ".gbc" or ".sgb" or ".zip" or ".gba")' '                if (extension is ".gb" or ".gbc" or ".sgb" or ".gba" or ".gbx" or ".agb" or ".dmg" or ".cgb" or ".bin" or ".rom" or ".pak" or ".zip" or ".7z")' "expanded drag and drop routing"
[System.IO.File]::WriteAllText($windowPath, $window, [System.Text.UTF8Encoding]::new($false))

# Replace the older desktop-only resolver with the shared implementation used by Android too.
$sharedLoader = @'
using System;
using System.IO;
using PocketGB.Shared;

namespace GameboySharp;

internal static class RomFileLoader
{
    private static string CacheDirectory
    {
        get
        {
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrWhiteSpace(local))
                local = Path.GetTempPath();
            return Path.Combine(local, "PocketGB", "rom-cache");
        }
    }

    public static string ResolveRomPath(string path) =>
        CartridgeFileLoader.ResolveRomPath(path, CacheDirectory);

    public static bool IsRomExtension(string extension) =>
        CartridgeFileLoader.IsSupportedRomExtension(extension);
}
'@
$romLoaderPath = Join-Path $vendor "RomFileLoader.cs"
[System.IO.File]::WriteAllText($romLoaderPath, $sharedLoader, [System.Text.UTF8Encoding]::new($false))

Write-Host "Desktop and portable builds now share the cross-platform ROM resolver." -ForegroundColor Green



# Test the complete managed-to-native path with a tiny synthetic GBA homebrew image.
# The test ROM contains a valid GBA entry-point signature and loops in place after boot.
$testDirectory = Join-Path $vendor "GameboySharp.Tests"
$testPath = Join-Path $testDirectory "MgbaNativeSmokeTests.cs"
$testSource = @'
using System;
using System.IO;
using System.IO.Compression;
using GameboySharp;
using Xunit;

namespace GameboySharp.Tests.Native;

public sealed class MgbaNativeSmokeTests
{
    [Fact]
    public void NativeCoreLoadsAndRunsSyntheticGbCartridge()
    {
        Environment.SetEnvironmentVariable("GBSHARP_AUDIO", "none");

        byte[] rom = new byte[32 * 1024];
        // A minimal program that loops forever at the cartridge entry point.
        rom[0x100] = 0x18; // JR
        rom[0x101] = 0xFE; // -2: branch back to 0x0100
        // mGBA's cartridge detector checks the Nintendo logo prefix at 0x0104.
        rom[0x104] = 0xCE;
        rom[0x105] = 0xED;
        rom[0x106] = 0x66;
        rom[0x107] = 0x66;
        byte[] title = System.Text.Encoding.ASCII.GetBytes("PGB GB TEST");
        Array.Copy(title, 0, rom, 0x134, title.Length);
        rom[0x147] = 0x00; // ROM-only
        rom[0x148] = 0x00; // 32 KiB ROM
        rom[0x149] = 0x00; // No external RAM

        byte headerChecksum = 0;
        for (int i = 0x134; i <= 0x14C; i++)
            headerChecksum = (byte)(headerChecksum - rom[i] - 1);
        rom[0x14D] = headerChecksum;

        string path = Path.Combine(Path.GetTempPath(), $"pocketgb-mgba-gb-smoke-{Guid.NewGuid():N}.gb");
        string statePath = Path.ChangeExtension(path, ".state0");
        File.WriteAllBytes(path, rom);
        try
        {
            using var core = new MgbaCore(new EmulatorConfig());
            core.LoadRom(path);

            Assert.True(core.HasRom);
            Assert.Equal("Game Boy / Color", core.PlatformName);
            Assert.Equal(160, core.FrameWidth);
            Assert.Equal(144, core.FrameHeight);
            Assert.Equal(160 * 144, core.FrameBuffer.Length);

            core.RunFrames(2);
            Assert.Equal(160 * 144, core.FrameBuffer.Length);

            core.SaveState();
            Assert.True(File.Exists(statePath));
            Assert.True(core.LoadState());
            Assert.Equal(160, core.FrameWidth);
            Assert.Equal(144, core.FrameHeight);
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
            if (File.Exists(statePath)) File.Delete(statePath);
            Environment.SetEnvironmentVariable("GBSHARP_AUDIO", null);
        }
    }

    [Fact]
    public void NativeCoreAppliesIpsSidecarBeforeReportingGameTitle()
    {
        Environment.SetEnvironmentVariable("GBSHARP_AUDIO", "none");

        byte[] rom = new byte[32 * 1024];
        rom[0x100] = 0x18;
        rom[0x101] = 0xFE;
        rom[0x104] = 0xCE;
        rom[0x105] = 0xED;
        rom[0x106] = 0x66;
        rom[0x107] = 0x66;
        byte[] title = System.Text.Encoding.ASCII.GetBytes("PGB IPS TEST");
        Array.Copy(title, 0, rom, 0x134, title.Length);
        rom[0x147] = 0x00;
        rom[0x148] = 0x00;
        rom[0x149] = 0x00;
        byte checksum = 0;
        for (int i = 0x134; i <= 0x14C; i++)
            checksum = (byte)(checksum - rom[i] - 1);
        rom[0x14D] = checksum;

        string path = Path.Combine(Path.GetTempPath(), $"pocketgb-gb-ips-{Guid.NewGuid():N}.gb");
        string patchPath = Path.ChangeExtension(path, ".ips");
        string statePath = Path.ChangeExtension(path, ".state0");
        byte[] patch =
        {
            0x50, 0x41, 0x54, 0x43, 0x48, // PATCH
            0x00, 0x01, 0x34,             // Offset 0x0134 (first title byte)
            0x00, 0x01,                   // One byte
            (byte)'X',
            0x45, 0x4F, 0x46              // EOF
        };

        File.WriteAllBytes(path, rom);
        File.WriteAllBytes(patchPath, patch);
        try
        {
            using var core = new MgbaCore(new EmulatorConfig());
            core.LoadRom(path);

            Assert.True(core.HasRom);
            Assert.StartsWith("XGB", core.GameTitle, StringComparison.Ordinal);
            core.RunFrames(2);
            core.SaveState();
            Assert.True(core.LoadState());
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
            if (File.Exists(patchPath)) File.Delete(patchPath);
            if (File.Exists(statePath)) File.Delete(statePath);
            Environment.SetEnvironmentVariable("GBSHARP_AUDIO", null);
        }
    }

    [Fact]
    public void NativeCoreLoadsSyntheticGbCartridgeFromNestedZipAndSavesBesideArchive()
    {
        Environment.SetEnvironmentVariable("GBSHARP_AUDIO", "none");

        byte[] rom = new byte[32 * 1024];
        rom[0x100] = 0x18;
        rom[0x101] = 0xFE;
        rom[0x104] = 0xCE;
        rom[0x105] = 0xED;
        rom[0x106] = 0x66;
        rom[0x107] = 0x66;
        byte[] title = System.Text.Encoding.ASCII.GetBytes("PGB ZIP TEST");
        Array.Copy(title, 0, rom, 0x134, title.Length);
        rom[0x147] = 0x00;
        rom[0x148] = 0x00;
        rom[0x149] = 0x00;
        byte checksum = 0;
        for (int i = 0x134; i <= 0x14C; i++)
            checksum = (byte)(checksum - rom[i] - 1);
        rom[0x14D] = checksum;

        string zipPath = Path.Combine(Path.GetTempPath(), $"pocketgb-gb-zip-{Guid.NewGuid():N}.zip");
        string savePath = Path.ChangeExtension(zipPath, ".state0");
        string? resolvedPath = null;
        try
        {
            using (var archive = ZipFile.Open(zipPath, ZipArchiveMode.Create))
            {
                var entry = archive.CreateEntry("nested/game.gb", CompressionLevel.Optimal);
                using var output = entry.Open();
                output.Write(rom, 0, rom.Length);
            }

            resolvedPath = RomFileLoader.ResolveRomPath(zipPath);
            using var core = new MgbaCore(new EmulatorConfig());
            core.LoadRom(zipPath);

            Assert.True(core.HasRom);
            Assert.Equal("Game Boy / Color", core.PlatformName);
            Assert.Equal(160, core.FrameWidth);
            Assert.Equal(144, core.FrameHeight);
            core.RunFrames(2);
            core.SaveState();
            Assert.True(File.Exists(savePath));
            Assert.True(core.LoadState());
        }
        finally
        {
            if (File.Exists(zipPath)) File.Delete(zipPath);
            if (File.Exists(savePath)) File.Delete(savePath);
            if (!string.IsNullOrWhiteSpace(resolvedPath) && File.Exists(resolvedPath))
            {
                string? cacheFolder = Path.GetDirectoryName(resolvedPath);
                File.Delete(resolvedPath);
                if (cacheFolder != null && Directory.Exists(cacheFolder) && Directory.GetFileSystemEntries(cacheFolder).Length == 0)
                    Directory.Delete(cacheFolder);
            }
            Environment.SetEnvironmentVariable("GBSHARP_AUDIO", null);
        }
    }

    [Theory]
    [InlineData((byte)0x80, (byte)0x00, ".gbc")]
    [InlineData((byte)0x00, (byte)0x03, ".sgb")]
    public void NativeCoreLoadsColorAndSgbTaggedCartridges(byte cgbFlag, byte sgbFlag, string extension)
    {
        Environment.SetEnvironmentVariable("GBSHARP_AUDIO", "none");

        byte[] rom = new byte[32 * 1024];
        rom[0x100] = 0x18; // JR -2: boot into a harmless loop.
        rom[0x101] = 0xFE;
        rom[0x104] = 0xCE;
        rom[0x105] = 0xED;
        rom[0x106] = 0x66;
        rom[0x107] = 0x66;
        byte[] title = System.Text.Encoding.ASCII.GetBytes("PGB COLOR TEST");
        Array.Copy(title, 0, rom, 0x134, Math.Min(15, title.Length));
        rom[0x143] = cgbFlag; // CGB-compatible flag.
        rom[0x146] = sgbFlag; // SGB flag 0x03, or 0 for a normal CGB test.
        rom[0x147] = 0x00;
        rom[0x148] = 0x00;
        rom[0x149] = 0x00;

        byte checksum = 0;
        for (int i = 0x134; i <= 0x14C; i++)
            checksum = (byte)(checksum - rom[i] - 1);
        rom[0x14D] = checksum;

        string path = Path.Combine(Path.GetTempPath(), $"pocketgb-mgba-color-{Guid.NewGuid():N}{extension}");
        string statePath = Path.ChangeExtension(path, ".state0");
        File.WriteAllBytes(path, rom);
        try
        {
            using var core = new MgbaCore(new EmulatorConfig());
            core.LoadRom(path);

            Assert.True(core.HasRom);
            Assert.Equal("Game Boy / Color", core.PlatformName);
            Assert.Equal(160, core.FrameWidth);
            Assert.Equal(144, core.FrameHeight);
            core.RunFrames(2);
            core.SaveState();
            Assert.True(core.LoadState());
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
            if (File.Exists(statePath)) File.Delete(statePath);
            Environment.SetEnvironmentVariable("GBSHARP_AUDIO", null);
        }
    }

    [Fact]
    public void NativeCoreRejectsRandomDataInsteadOfStartingAnEmptyGame()
    {
        Environment.SetEnvironmentVariable("GBSHARP_AUDIO", "none");
        string path = Path.Combine(Path.GetTempPath(), $"pocketgb-invalid-{Guid.NewGuid():N}.gba");
        File.WriteAllBytes(path, new byte[4096]);
        try
        {
            using var core = new MgbaCore(new EmulatorConfig());
            Assert.Throws<InvalidDataException>(() => core.LoadRom(path));
            Assert.False(core.HasRom);
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
            Environment.SetEnvironmentVariable("GBSHARP_AUDIO", null);
        }
    }

    [Theory]
    [InlineData(".gba")]
    [InlineData(".pak")]
    public void NativeCoreLoadsAndRunsSyntheticGbaCartridge(string extension)
    {
        Environment.SetEnvironmentVariable("GBSHARP_AUDIO", "none");

        byte[] rom = new byte[32 * 1024];

        // ARM branch from the GBA reset vector at 0x08000000 to 0x080000C0.
        rom[0x00] = 0x2E;
        rom[0x01] = 0x00;
        rom[0x02] = 0x00;
        rom[0x03] = 0xEA;

        // A tight ARM branch-to-self loop at 0x080000C0 keeps the homebrew test ROM running.
        rom[0xC0] = 0xFE;
        rom[0xC1] = 0xFF;
        rom[0xC2] = 0xFF;
        rom[0xC3] = 0xEA;

        // Required GBA cartridge header marker.
        rom[0xB2] = 0x96;

        // Printable title and game code for deterministic game-info parsing.
        byte[] title = System.Text.Encoding.ASCII.GetBytes("PGB SMOKE   ");
        Array.Copy(title, 0, rom, 0xA0, Math.Min(12, title.Length));
        byte[] code = System.Text.Encoding.ASCII.GetBytes("PGBA");
        Array.Copy(code, 0, rom, 0xAC, 4);

        string path = Path.Combine(Path.GetTempPath(), $"pocketgb-mgba-smoke-{Guid.NewGuid():N}{extension}");
        string statePath = Path.ChangeExtension(path, ".state0");

        File.WriteAllBytes(path, rom);
        try
        {
            using var core = new MgbaCore(new EmulatorConfig());
            core.LoadRom(path);

            Assert.True(core.HasRom);
            Assert.Equal(240, core.FrameWidth);
            Assert.Equal(160, core.FrameHeight);
            Assert.Equal(240 * 160, core.FrameBuffer.Length);

            core.RunFrames(2);
            Assert.Equal(240 * 160, core.FrameBuffer.Length);

            core.SaveState();
            Assert.True(File.Exists(statePath));
            Assert.True(core.LoadState());
            Assert.Equal(240, core.FrameWidth);
            Assert.Equal(160, core.FrameHeight);
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
            if (File.Exists(statePath)) File.Delete(statePath);
            Environment.SetEnvironmentVariable("GBSHARP_AUDIO", null);
        }
    }
}
'@

New-Item -ItemType Directory -Force $testDirectory | Out-Null
[System.IO.File]::WriteAllText($testPath, $testSource, [System.Text.UTF8Encoding]::new($false))

$reloadTestPath = Join-Path $testDirectory "MgbaNativeReloadTests.cs"
$reloadTestSource = @'
using System;
using System.IO;
using GameboySharp;
using Xunit;

namespace GameboySharp.Tests.Native;

public sealed class MgbaNativeReloadTests
{
    private static byte[] CreateGbRom()
    {
        byte[] rom = new byte[32 * 1024];
        rom[0x100] = 0x18;
        rom[0x101] = 0xFE;
        rom[0x104] = 0xCE;
        rom[0x105] = 0xED;
        rom[0x106] = 0x66;
        rom[0x107] = 0x66;
        byte[] title = System.Text.Encoding.ASCII.GetBytes("PGB RELOAD GB");
        Array.Copy(title, 0, rom, 0x134, title.Length);
        rom[0x147] = 0x00;
        rom[0x148] = 0x00;
        rom[0x149] = 0x00;
        byte checksum = 0;
        for (int i = 0x134; i <= 0x14C; i++)
            checksum = (byte)(checksum - rom[i] - 1);
        rom[0x14D] = checksum;
        return rom;
    }

    private static byte[] CreateGbaRom()
    {
        byte[] rom = new byte[32 * 1024];
        rom[0x00] = 0x2E;
        rom[0x01] = 0x00;
        rom[0x02] = 0x00;
        rom[0x03] = 0xEA;
        rom[0xC0] = 0xFE;
        rom[0xC1] = 0xFF;
        rom[0xC2] = 0xFF;
        rom[0xC3] = 0xEA;
        rom[0xB2] = 0x96;
        byte[] title = System.Text.Encoding.ASCII.GetBytes("PGB RELOAD   ");
        Array.Copy(title, 0, rom, 0xA0, 12);
        byte[] code = System.Text.Encoding.ASCII.GetBytes("PGRL");
        Array.Copy(code, 0, rom, 0xAC, 4);
        return rom;
    }

    [Fact]
    public void ReusesNativeContextAcrossRepeatedGbAndGbaLoads()
    {
        string? previousAudioSetting = Environment.GetEnvironmentVariable("GBSHARP_AUDIO");
        Environment.SetEnvironmentVariable("GBSHARP_AUDIO", "none");
        string gbPath = Path.Combine(Path.GetTempPath(), $"pocketgb-reload-{Guid.NewGuid():N}.gb");
        string gbaPath = Path.Combine(Path.GetTempPath(), $"pocketgb-reload-{Guid.NewGuid():N}.gba");
        File.WriteAllBytes(gbPath, CreateGbRom());
        File.WriteAllBytes(gbaPath, CreateGbaRom());

        try
        {
            using var core = new MgbaCore(new EmulatorConfig());
            for (int i = 0; i < 20; i++)
            {
                bool gba = (i & 1) != 0;
                core.LoadRom(gba ? gbaPath : gbPath);
                Assert.True(core.HasRom);
                Assert.Equal(gba ? 240 : 160, core.FrameWidth);
                Assert.Equal(gba ? 160 : 144, core.FrameHeight);
                core.RunFrames(3);
            }
        }
        finally
        {
            if (File.Exists(gbPath)) File.Delete(gbPath);
            if (File.Exists(gbaPath)) File.Delete(gbaPath);
            Environment.SetEnvironmentVariable("GBSHARP_AUDIO", previousAudioSetting);
        }
    }
}
'@
[System.IO.File]::WriteAllText($reloadTestPath, $reloadTestSource, [System.Text.UTF8Encoding]::new($false))

Write-Host "Native mGBA GBA frame and save-state smoke test generated." -ForegroundColor Green
