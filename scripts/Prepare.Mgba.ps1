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
            ImGui.TextDisabled("Auto uses mGBA for .gba and GameboySharp for .gb/.gbc. GBA always requires mGBA.");

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
'@ "mGBA game routing callback"

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
                bool requiresMgba = extension.Equals(".gba", StringComparison.OrdinalIgnoreCase) ||
                    _config.General.EmulationBackend == EmulationBackend.Mgba;

                if (requiresMgba)
                {
                    if (OpenMgbaGameRequested == null)
                        throw new InvalidOperationException("The mGBA window is not available in this build.");
                    OpenMgbaGameRequested(path);
                    return;
                }

                _emulator.LoadRom(resolvedPath, path);
                _config.AddRecentRom(path);
                ConfigStore.Save(_config);
                Log.Information("Loaded ROM with GameboySharp: {Path}", path);
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Failed to load ROM: {Path}", path);
            }
        }

'@
$window = $window.Substring(0, $loadStart) + $newLoadMethod + $window.Substring($loadEnd)
[System.IO.File]::WriteAllText($windowPath, $window, [System.Text.UTF8Encoding]::new($false))

# Include the managed adapters and built native DLL in the Windows app publish directory.
$projectPath = Join-Path $vendor "GameboySharp.csproj"
$project = [System.IO.File]::ReadAllText($projectPath)
if (-not $project.Contains("native/mgba/managed/*.cs")) {
    $items = @'
  <ItemGroup>
    <Compile Include="../../native/mgba/managed/*.cs" />
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
                bool useMgba = Path.GetExtension(resolvedPath).Equals(".gba", StringComparison.OrdinalIgnoreCase) ||
                    config.General.EmulationBackend == EmulationBackend.Mgba;
                if (useMgba) mgbaStartupRom = args[0];
                else emulator.LoadRom(resolvedPath, args[0]);
                config.AddRecentRom(args[0]);
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Failed to load game file at '{Path}'. Open another game from the toolbar.", args[0]);
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
                : !emulator.HasRom || emulator.IsPaused;

            int framesToRun = framePacer.Consume(elapsedSeconds, requestedSpeed, gameFrameRate, paused);

            if (useMgba)
            {
                mgbaWindow!.RunFrames(framesToRun);
                mgbaWindow.RecordEmulatedFrames(framesToRun);
            }
            else
            {
                emulator.RunFrames(framesToRun);
                gameWindow.RecordEmulatedFrames(framesToRun);
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
