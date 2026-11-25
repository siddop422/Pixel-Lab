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
