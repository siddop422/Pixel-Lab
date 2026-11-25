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
