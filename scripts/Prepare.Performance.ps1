$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$vendor = Join-Path $root "vendor/GameboySharp"
function Replace-ExactlyOnce([string]$Source, [string]$Old, [string]$New, [string]$Label) {
    $count = ([regex]::Matches($Source, [regex]::Escape($Old))).Count
    if ($count -ne 1) { throw "Expected one $Label anchor, found $count." }
    return $Source.Replace($Old, $New)
}

# Frame scheduler: emulated frame count is driven by elapsed wall time multiplied by
# the requested speed. Presentation cadence is independent from emulated cadence.
$pacerPath = Join-Path $vendor "UI/EmulationFramePacer.cs"
$pacer = @'
using System;

namespace GameboySharp
{
    internal sealed class EmulationFramePacer
    {
        internal const int MaxFramesPerBatch = 32;
        private double _fractionalFrames;

        public int Consume(double elapsedSeconds, double speedMultiplier, double frameRate, bool paused)
        {
            if (paused) { Reset(); return 0; }
            if (!double.IsFinite(elapsedSeconds) || elapsedSeconds <= 0 ||
                !double.IsFinite(speedMultiplier) || speedMultiplier <= 0 ||
                !double.IsFinite(frameRate) || frameRate <= 0) return 0;

            // Drop stale time after a debugger pause or long OS stall instead of freezing
            // the UI while trying to catch up with several seconds of emulation.
            double elapsed = Math.Min(elapsedSeconds, 0.25);
            double speed = Math.Clamp(speedMultiplier, 0.1, 16.0);
            _fractionalFrames = Math.Min(MaxFramesPerBatch,
                _fractionalFrames + elapsed * speed * frameRate);

            int frames = Math.Min(MaxFramesPerBatch, (int)Math.Floor(_fractionalFrames + 1e-9));
            _fractionalFrames -= frames;
            return frames;
        }

        public void Reset() => _fractionalFrames = 0;
    }
}
'@
[System.IO.File]::WriteAllText($pacerPath, $pacer, [System.Text.UTF8Encoding]::new($false))

# Run multiple core frames in one host tick and service audio once per batch.
$emulatorPath = Join-Path $vendor "Emulator.cs"
$emulator = [System.IO.File]::ReadAllText($emulatorPath)
$oldRunFrame = @'
        public void RunFrame()
        {
            if (!Cpu.IsPaused)
            {
                RunOneFrame();
            }

            // Always service the audio backend, even while paused, so the device stays fed and
            // alive. The main loop handles frame pacing, so there is no busy-wait here.
            AudioSink?.Update();

            // Flush battery RAM to disk now and then so progress survives a crash, not just a clean exit.
            MaybeAutosaveBattery();
        }
'@
$newRunFrame = @'
        public void RunFrame() => RunFrames(1);

        public void RunFrames(int frameCount)
        {
            if (frameCount < 0 || frameCount > EmulationFramePacer.MaxFramesPerBatch)
                throw new ArgumentOutOfRangeException(nameof(frameCount));

            if (!Cpu.IsPaused && HasRom)
            {
                for (int i = 0; i < frameCount; i++) RunOneFrame();
            }

            AudioSink?.Update();
            MaybeAutosaveBattery();
        }
'@
$emulator = Replace-ExactlyOnce $emulator $oldRunFrame $newRunFrame "batched frame API"
[System.IO.File]::WriteAllText($emulatorPath, $emulator, [System.Text.UTF8Encoding]::new($false))

# Add a selectable turbo multiplier (Tab is still hold-to-turbo).
$configPath = Join-Path $vendor "Config/EmulatorConfig.cs"
$config = [System.IO.File]::ReadAllText($configPath)
$config = Replace-ExactlyOnce $config '        public double SpeedMultiplier { get; set; } = 1.0;' @'
        public double SpeedMultiplier { get; set; } = 1.0;
        public double TurboSpeedMultiplier { get; set; } = 4.0;
'@ "turbo speed setting"
[System.IO.File]::WriteAllText($configPath, $config, [System.Text.UTF8Encoding]::new($false))

# Expose turbo speed selection in Settings > General.
$settingsPath = Join-Path $vendor "UI/SettingsDialog.cs"
$settings = [System.IO.File]::ReadAllText($settingsPath)
$settings = Replace-ExactlyOnce $settings @'
            bool muteDuringTurbo = _config.General.MuteDuringTurbo;
            if (ImGui.Checkbox("Mute audio during fast-forward", ref muteDuringTurbo))
            {
                _config.General.MuteDuringTurbo = muteDuringTurbo;
            }

            string saveDir = _config.General.SaveDirectory;
'@ @'
            bool muteDuringTurbo = _config.General.MuteDuringTurbo;
            if (ImGui.Checkbox("Mute audio during fast-forward", ref muteDuringTurbo))
            {
                _config.General.MuteDuringTurbo = muteDuringTurbo;
            }

            string[] turboLabels = { "2x", "4x", "6x", "8x", "12x", "16x" };
            double[] turboValues = { 2.0, 4.0, 6.0, 8.0, 12.0, 16.0 };
            int turboIndex = 1;
            double closestDistance = double.MaxValue;
            for (int i = 0; i < turboValues.Length; i++)
            {
                double distance = Math.Abs(_config.General.TurboSpeedMultiplier - turboValues[i]);
                if (distance < closestDistance) { closestDistance = distance; turboIndex = i; }
            }
            if (ImGui.Combo("Turbo speed while holding Tab", ref turboIndex, turboLabels, turboLabels.Length))
                _config.General.TurboSpeedMultiplier = turboValues[turboIndex];

            string saveDir = _config.General.SaveDirectory;
'@ "turbo speed settings UI"
[System.IO.File]::WriteAllText($settingsPath, $settings, [System.Text.UTF8Encoding]::new($false))

Write-Host "Core frame batching and configurable turbo speed prepared." -ForegroundColor Green

# Add live counters: render FPS is intentionally different from actual emulated game FPS.
$windowPath = Join-Path $vendor "UI/GameWindow.cs"
$window = [System.IO.File]::ReadAllText($windowPath)
if (-not $window.Contains('using System.Diagnostics;')) {
    $window = Replace-ExactlyOnce $window 'using System;' ('using System;' + [Environment]::NewLine + 'using System.Diagnostics;') "Stopwatch import"
}
$window = Replace-ExactlyOnce $window @'
        private double _fps;
        private int _titleUpdateCounter;

        // True while the turbo/fast-forward key is held. The main loop reads this to drop frame pacing.
'@ @'
        private double _fps;
        private int _titleUpdateCounter;
        private double _emulatedFps;
        private int _emulatedFramesInSample;
        private readonly Stopwatch _emulationStatsTimer = Stopwatch.StartNew();

        // True while the turbo/fast-forward key is held.
'@ "emulated FPS fields"
$window = Replace-ExactlyOnce $window @'
            _toolbar.Draw(_fps);
            _fileBrowser.Draw();
'@ @'
            _toolbar.Draw(_fps);
            DrawPerformanceOverlay();
            _fileBrowser.Draw();
'@ "performance overlay call"
$methods = @'
        public void RecordEmulatedFrames(int frameCount)
        {
            if (frameCount <= 0) return;
            _emulatedFramesInSample += frameCount;
            double elapsed = _emulationStatsTimer.Elapsed.TotalSeconds;
            if (elapsed >= 0.5)
            {
                double measured = _emulatedFramesInSample / elapsed;
                _emulatedFps = _emulatedFps <= 0 ? measured : (_emulatedFps * 0.55) + (measured * 0.45);
                _emulatedFramesInSample = 0;
                _emulationStatsTimer.Restart();
            }
        }

        private void DrawPerformanceOverlay()
        {
            var viewport = ImGui.GetMainViewport();
            ImGui.SetNextWindowPos(new Vector2(viewport.Pos.X + viewport.Size.X - 12f,
                viewport.Pos.Y + Toolbar.HeightPoints + 8f), ImGuiCond.Always, new Vector2(1f, 0f));
            ImGui.SetNextWindowBgAlpha(0.78f);
            const ImGuiWindowFlags flags =
                ImGuiWindowFlags.NoTitleBar | ImGuiWindowFlags.NoResize | ImGuiWindowFlags.NoMove |
                ImGuiWindowFlags.NoScrollbar | ImGuiWindowFlags.NoSavedSettings |
                ImGuiWindowFlags.NoFocusOnAppearing | ImGuiWindowFlags.NoNav |
                ImGuiWindowFlags.NoInputs | ImGuiWindowFlags.AlwaysAutoResize;
            if (ImGui.Begin("##pocketgb-performance", flags))
            {
                ImGui.Text(string.Format("RENDER  {0:0} FPS", _fps));
                ImGui.Text(string.Format("GAME    {0:0.0} FPS", _emulatedFps));
                double measuredSpeed = _emulatedFps / GameboyConstants.FramesPerSecond;
                ImGui.TextColored(_turboActive ? new Vector4(0.48f, 0.95f, 0.62f, 1f) :
                    new Vector4(0.78f, 0.86f, 0.81f, 1f),
                    string.Format(_turboActive ? "TURBO  {0:0.00}x" : "SPEED  {0:0.00}x", measuredSpeed));
            }
            ImGui.End();
        }

'@
if (-not $window.Contains('private void DrawPerformanceOverlay()')) {
    $window = Replace-ExactlyOnce $window '        public void Dispose()' ($methods + '        public void Dispose()') "performance overlay method"
}
$window = Replace-ExactlyOnce $window '                _window.Title = $"PocketGB — {_emulator.CurrentRomName} — {_fps:0} FPS";' '                _window.Title = string.Format("{0} — Render {1:0} FPS | Game {2:0.0} FPS", _emulator.CurrentRomName, _fps, _emulatedFps);' "dual FPS title"
[System.IO.File]::WriteAllText($windowPath, $window, [System.Text.UTF8Encoding]::new($false))

# Program.cs is generated by Prepare.ps1; its main loop is patched there before this script runs.

# Make GBA files visible so the application can explain that the separate GBA engine is missing.
$fileBrowserPath = Join-Path $vendor "UI/FileBrowser.cs"
$fileBrowser = [System.IO.File]::ReadAllText($fileBrowserPath)
$fileBrowser = Replace-ExactlyOnce $fileBrowser '        private static readonly string[] RomExtensions = { ".gb", ".gbc", ".sgb", ".zip" };' '        private static readonly string[] RomExtensions = { ".gb", ".gbc", ".sgb", ".zip", ".gba" };' "GBA file browser filter"
[System.IO.File]::WriteAllText($fileBrowserPath, $fileBrowser, [System.Text.UTF8Encoding]::new($false))

$windowPath = Join-Path $vendor "UI/GameWindow.cs"
$window = [System.IO.File]::ReadAllText($windowPath)
$window = Replace-ExactlyOnce $window '                if (extension is ".gb" or ".gbc" or ".sgb" or ".zip")' '                if (extension is ".gb" or ".gbc" or ".sgb" or ".zip" or ".gba")' "GBA drag/drop routing"
[System.IO.File]::WriteAllText($windowPath, $window, [System.Text.UTF8Encoding]::new($false))

$romLoaderPath = Join-Path $vendor "RomFileLoader.cs"
$romLoader = [System.IO.File]::ReadAllText($romLoaderPath)
$romLoader = Replace-ExactlyOnce $romLoader @'
            string extension = Path.GetExtension(fullPath);
            if (!extension.Equals(".zip", StringComparison.OrdinalIgnoreCase))
            {
                if (!IsRomExtension(extension))
'@ @'
            string extension = Path.GetExtension(fullPath);
            if (extension.Equals(".gba", StringComparison.OrdinalIgnoreCase))
            {
                throw new NotSupportedException(
                    "This is a Game Boy Advance ROM. The current PocketGB core only emulates Game Boy and Game Boy Color; a separate GBA core such as mGBA is required. The ROM file has not been modified.");
            }

            if (!extension.Equals(".zip", StringComparison.OrdinalIgnoreCase))
            {
                if (!IsRomExtension(extension))
'@ "GBA core requirement diagnostic"
[System.IO.File]::WriteAllText($romLoaderPath, $romLoader, [System.Text.UTF8Encoding]::new($false))

# Scheduler regression tests run in CI without distributing any copyrighted ROMs.
$testsDirectory = Join-Path $vendor "GameboySharp.Tests"
$testPath = Join-Path $testsDirectory "Performance/EmulationFramePacerTests.cs"
New-Item -ItemType Directory -Force (Split-Path -Parent $testPath) | Out-Null
$tests = @'
using GameboySharp;
using Xunit;

namespace GameboySharp.Tests.Performance;

public sealed class EmulationFramePacerTests
{
    private static int RunForOneSecond(double speed)
    {
        var pacer = new EmulationFramePacer();
        int total = 0;
        for (int i = 0; i < 60; i++)
            total += pacer.Consume(1.0 / 60.0, speed, 60.0, paused: false);
        return total;
    }

    [Fact] public void HalfSpeedAdvancesHalfAsManyFrames() => Assert.Equal(30, RunForOneSecond(0.5));
    [Fact] public void NormalSpeedAdvancesOneGameSecond() => Assert.Equal(60, RunForOneSecond(1.0));
    [Fact] public void DoubleSpeedAdvancesTwiceAsManyFrames() => Assert.Equal(120, RunForOneSecond(2.0));
    [Fact] public void TurboAdvancesConfiguredFrameCount() => Assert.Equal(480, RunForOneSecond(8.0));

    [Fact]
    public void BatchIsBoundedAfterLongStall()
    {
        var pacer = new EmulationFramePacer();
        Assert.Equal(32, pacer.Consume(5.0, 16.0, 60.0, paused: false));
    }

    [Fact]
    public void PauseClearsFractionalFrameDebt()
    {
        var pacer = new EmulationFramePacer();
        Assert.Equal(0, pacer.Consume(0.5 / 60.0, 1.0, 60.0, paused: false));
        Assert.Equal(0, pacer.Consume(1.0, 8.0, 60.0, paused: true));
        Assert.Equal(0, pacer.Consume(0.5 / 60.0, 1.0, 60.0, paused: false));
        Assert.Equal(1, pacer.Consume(0.5 / 60.0, 1.0, 60.0, paused: false));
    }
}
'@
[System.IO.File]::WriteAllText($testPath, $tests, [System.Text.UTF8Encoding]::new($false))
