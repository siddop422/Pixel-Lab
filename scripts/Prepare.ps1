$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$vendor = Join-Path $root "vendor/GameboySharp"
$windowPath = Join-Path $vendor "UI/GameWindow.cs"
$configPath = Join-Path $vendor "Config/ConfigStore.cs"
$programPath = Join-Path $vendor "Program.cs"

foreach ($path in @($windowPath, $configPath, $programPath)) {
    if (-not (Test-Path $path)) { throw "Missing expected upstream source file: $path. Did you clone the submodule?" }
}

$newLine = [Environment]::NewLine
$window = [System.IO.File]::ReadAllText($windowPath)
$window = $window.Replace('options.Title = "Game Boy Emulator";', 'options.Title = "PocketGB | Game Boy + Color";')

$themeAnchor = '_imGuiController = new ImGuiController(_gl, _window, _inputContext);'
if (-not $window.Contains('ApplyPocketGBTheme();')) {
    if (-not $window.Contains($themeAnchor)) { throw "Could not find ImGui initialization anchor in GameWindow.cs." }
    $window = $window.Replace($themeAnchor, $themeAnchor + $newLine + '            ApplyPocketGBTheme();')
}

if (-not $window.Contains('private void DrawWelcomeScreen()')) {
    $drawAnchor = '            DrawResetConfirm();'
    if (-not $window.Contains($drawAnchor)) { throw "Could not find DrawUi anchor in GameWindow.cs." }
    $window = $window.Replace($drawAnchor, $drawAnchor + $newLine + '            if (!_emulator.HasRom) DrawWelcomeScreen();')

    $welcomeMethod = @'
        private static void ApplyPocketGBTheme()
        {
            var style = ImGui.GetStyle();
            style.WindowRounding = 14f;
            style.ChildRounding = 10f;
            style.FrameRounding = 8f;
            style.PopupRounding = 10f;
            style.ScrollbarRounding = 8f;
            style.GrabRounding = 7f;
            style.WindowPadding = new Vector2(18f, 16f);
            style.FramePadding = new Vector2(12f, 8f);
            style.ItemSpacing = new Vector2(10f, 8f);

            var colors = style.Colors;
            colors[(int)ImGuiCol.Text] = new Vector4(0.91f, 0.95f, 0.92f, 1f);
            colors[(int)ImGuiCol.TextDisabled] = new Vector4(0.53f, 0.62f, 0.57f, 1f);
            colors[(int)ImGuiCol.WindowBg] = new Vector4(0.055f, 0.075f, 0.070f, 1f);
            colors[(int)ImGuiCol.ChildBg] = new Vector4(0.075f, 0.105f, 0.090f, 1f);
            colors[(int)ImGuiCol.PopupBg] = new Vector4(0.075f, 0.095f, 0.085f, 0.98f);
            colors[(int)ImGuiCol.Border] = new Vector4(0.18f, 0.27f, 0.21f, 1f);
            colors[(int)ImGuiCol.FrameBg] = new Vector4(0.12f, 0.17f, 0.14f, 1f);
            colors[(int)ImGuiCol.FrameBgHovered] = new Vector4(0.17f, 0.27f, 0.20f, 1f);
            colors[(int)ImGuiCol.FrameBgActive] = new Vector4(0.21f, 0.34f, 0.24f, 1f);
            colors[(int)ImGuiCol.Button] = new Vector4(0.15f, 0.31f, 0.20f, 1f);
            colors[(int)ImGuiCol.ButtonHovered] = new Vector4(0.22f, 0.43f, 0.28f, 1f);
            colors[(int)ImGuiCol.ButtonActive] = new Vector4(0.28f, 0.51f, 0.33f, 1f);
            colors[(int)ImGuiCol.Header] = new Vector4(0.13f, 0.27f, 0.18f, 1f);
            colors[(int)ImGuiCol.HeaderHovered] = new Vector4(0.19f, 0.38f, 0.24f, 1f);
            colors[(int)ImGuiCol.HeaderActive] = new Vector4(0.24f, 0.45f, 0.29f, 1f);
            colors[(int)ImGuiCol.TitleBg] = new Vector4(0.045f, 0.065f, 0.060f, 1f);
            colors[(int)ImGuiCol.TitleBgActive] = new Vector4(0.08f, 0.13f, 0.10f, 1f);
        }

        private void DrawWelcomeScreen()
        {
            var viewport = ImGui.GetMainViewport();
            var size = new Vector2(
                Math.Min(620f, Math.Max(320f, viewport.Size.X - 36f)),
                Math.Min(390f, Math.Max(280f, viewport.Size.Y - 70f)));
            var position = viewport.Pos + new Vector2(
                Math.Max(12f, (viewport.Size.X - size.X) * 0.5f),
                Math.Max(42f, (viewport.Size.Y - size.Y) * 0.5f));

            ImGui.SetNextWindowPos(position, ImGuiCond.Always);
            ImGui.SetNextWindowSize(size, ImGuiCond.Always);

            const ImGuiWindowFlags flags =
                ImGuiWindowFlags.NoTitleBar | ImGuiWindowFlags.NoResize |
                ImGuiWindowFlags.NoMove | ImGuiWindowFlags.NoCollapse |
                ImGuiWindowFlags.NoSavedSettings;

            if (ImGui.Begin("##pocketgb-welcome", flags))
            {
                ImGui.TextColored(new Vector4(0.55f, 0.88f, 0.63f, 1f), "POCKETGB");
                ImGui.SameLine();
                ImGui.TextDisabled("GAME BOY  /  GAME BOY COLOR");
                ImGui.Separator();
                ImGui.Spacing();
                ImGui.TextUnformatted("Your handheld. Your games. Your saves.");
                ImGui.TextWrapped("Open a legally obtained .gb, .gbc, or .sgb game file to start playing.");
                ImGui.Spacing();

                if (ImGui.Button("OPEN A GAME", new Vector2(178f, 42f)))
                {
                    _fileBrowser.Open();
                }
                ImGui.SameLine();
                if (ImGui.Button("SETTINGS", new Vector2(132f, 42f)))
                {
                    _settingsDialog.Open();
                }

                ImGui.Spacing();
                ImGui.Separator();
                ImGui.TextDisabled("RECENT GAMES");

                ImGui.BeginChild("##pocketgb-recent-games", new Vector2(0f, 132f), ImGuiChildFlags.Borders);
                if (_config.RecentRoms.Count == 0)
                {
                    ImGui.TextDisabled("No recent games yet. Load your first ROM to begin.");
                }
                else
                {
                    int count = Math.Min(6, _config.RecentRoms.Count);
                    for (int i = 0; i < count; i++)
                    {
                        string path = _config.RecentRoms[i];
                        bool exists = File.Exists(path);
                        if (!exists) ImGui.BeginDisabled();
                        string label = Path.GetFileNameWithoutExtension(path) + (exists ? "" : "  (file missing)");
                        if (ImGui.Selectable(label))
                        {
                            if (exists) LoadRomFromUi(path);
                        }
                        if (!exists) ImGui.EndDisabled();
                    }
                }
                ImGui.EndChild();
            }
            ImGui.End();
        }

'@
    $methodAnchor = '        private void ComputeGameViewport('
    if (-not $window.Contains($methodAnchor)) { throw "Could not find method insertion point in GameWindow.cs." }
    $window = $window.Replace($methodAnchor, $welcomeMethod + $methodAnchor)
}

$window = $window.Replace('$"{_emulator.CurrentRomName} — {_fps:0} FPS"', '$"PocketGB — {_emulator.CurrentRomName} — {_fps:0} FPS"')
[System.IO.File]::WriteAllText($windowPath, $window, [System.Text.UTF8Encoding]::new($false))

$config = [System.IO.File]::ReadAllText($configPath)
$config = $config.Replace('private const string AppFolderName = "GameboySharp";', 'private const string AppFolderName = "PocketGB";')
[System.IO.File]::WriteAllText($configPath, $config, [System.Text.UTF8Encoding]::new($false))

$program = [System.IO.File]::ReadAllText($programPath)
$program = $program.Replace('logs/gameboysharp-.log', 'logs/pocketgb-.log')
[System.IO.File]::WriteAllText($programPath, $program, [System.Text.UTF8Encoding]::new($false))

Write-Host "PocketGB branding and welcome UI prepared." -ForegroundColor Green


# ZIP ROM detection and extraction. The archive itself is kept in Recent Games; the extracted ROM
# is cached in PocketGB's application-data folder so battery saves and save-state slots stay stable.
$romLoaderPath = Join-Path $vendor "RomFileLoader.cs"
$romLoaderSource = @'
using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using Serilog;

namespace GameboySharp
{
    internal static class RomFileLoader
    {
        private const long MaxRomBytes = 64L * 1024L * 1024L;
        private static readonly string[] RomExtensions = { ".gb", ".gbc", ".sgb" };

        public static string ResolveRomPath(string path)
        {
            if (string.IsNullOrWhiteSpace(path))
                throw new ArgumentException("A ROM file path is required.", nameof(path));

            string fullPath = Path.GetFullPath(path);
            if (!File.Exists(fullPath))
                throw new FileNotFoundException("The selected game file could not be found.", fullPath);

            string extension = Path.GetExtension(fullPath);
            if (!extension.Equals(".zip", StringComparison.OrdinalIgnoreCase))
            {
                if (!IsRomExtension(extension))
                    throw new InvalidDataException("PocketGB supports .gb, .gbc, .sgb ROM files and .zip archives containing them.");
                return fullPath;
            }

            using ZipArchive archive = ZipFile.OpenRead(fullPath);
            var candidates = archive.Entries
                .Where(entry => !string.IsNullOrEmpty(entry.Name))
                .Where(entry => IsRomExtension(Path.GetExtension(entry.Name)))
                .Where(entry => entry.Length > 0 && entry.Length <= MaxRomBytes)
                .OrderBy(entry => entry.FullName.Count(ch => ch == '/' || ch == '\\'))
                .ThenBy(entry => entry.FullName, StringComparer.OrdinalIgnoreCase)
                .ToList();

            if (candidates.Count == 0)
                throw new InvalidDataException("This ZIP archive does not contain a supported .gb, .gbc, or .sgb ROM.");

            if (candidates.Count > 1)
                Log.Warning("ZIP archive {Archive} contains {Count} Game Boy ROMs. Opening the first entry: {Entry}",
                    fullPath, candidates.Count, candidates[0].FullName);

            ZipArchiveEntry selected = candidates[0];
            string archiveHash;
            using (FileStream archiveStream = File.OpenRead(fullPath))
            {
                archiveHash = Convert.ToHexString(SHA256.HashData(archiveStream)).ToLowerInvariant();
            }

            // Hash the archive bytes, not only its timestamp and entry length: copied/replaced ZIPs
            // can preserve timestamps and lengths while containing a different game.
            string identity = archiveHash + "|" + selected.FullName + "|" + selected.Length;
            string hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity))).ToLowerInvariant();

            string localData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrWhiteSpace(localData))
                localData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);

            string cacheDirectory = Path.Combine(localData, "PocketGB", "rom-cache", hash);
            string safeName = Path.GetFileName(selected.FullName.Replace('\\', '/'));
            string destination = Path.Combine(cacheDirectory, safeName);

            if (File.Exists(destination) && new FileInfo(destination).Length == selected.Length)
                return destination;

            Directory.CreateDirectory(cacheDirectory);
            string temporary = destination + ".tmp";
            try
            {
                using Stream input = selected.Open();
                using (var output = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    byte[] buffer = new byte[81920];
                    long written = 0;
                    int read;
                    while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        written += read;
                        if (written > MaxRomBytes)
                            throw new InvalidDataException("The ROM inside this ZIP is larger than the supported safety limit.");
                        output.Write(buffer, 0, read);
                    }

                    if (written != selected.Length)
                        throw new InvalidDataException("The ROM entry in this ZIP archive was incomplete or corrupt.");
                }

                File.Move(temporary, destination, true);
            }
            finally
            {
                if (File.Exists(temporary))
                    File.Delete(temporary);
            }

            Log.Information("Opened ROM {Entry} from ZIP archive {Archive}", selected.FullName, fullPath);
            return destination;
        }

        private static bool IsRomExtension(string extension) =>
            RomExtensions.Contains(extension, StringComparer.OrdinalIgnoreCase);
    }
}
'@
[System.IO.File]::WriteAllText($romLoaderPath, $romLoaderSource, [System.Text.UTF8Encoding]::new($false))

# Let the in-app browser discover direct ROMs and ZIP containers.
$fileBrowserPath = Join-Path $vendor "UI/FileBrowser.cs"
$fileBrowser = [System.IO.File]::ReadAllText($fileBrowserPath)
$fileBrowser = $fileBrowser.Replace(
    'private static readonly string[] RomExtensions = { ".gb", ".gbc", ".sgb" };',
    'private static readonly string[] RomExtensions = { ".gb", ".gbc", ".sgb", ".zip" };')
$fileBrowser = $fileBrowser.Replace(
    'string name = Path.GetFileName(file);',
    'string name = Path.GetFileName(file);' + $newLine + '                if (Path.GetExtension(file).Equals(".zip", StringComparison.OrdinalIgnoreCase)) name += "  [ZIP]";')
$fileBrowser = $fileBrowser.Replace(
    'ImGui.SetNextWindowPos(viewport.Pos + viewport.Size * 0.5f, ImGuiCond.Appearing, new Vector2(0.5f, 0.5f));' + $newLine + '            ImGui.SetNextWindowSize(new Vector2(640, 460), ImGuiCond.Appearing);',
    'var dialogSize = new Vector2(Math.Min(760f, Math.Max(320f, viewport.Size.X - 32f)), Math.Min(540f, Math.Max(280f, viewport.Size.Y - 76f)));' + $newLine + '            ImGui.SetNextWindowPos(viewport.Pos + viewport.Size * 0.5f, ImGuiCond.Appearing, new Vector2(0.5f, 0.5f));' + $newLine + '            ImGui.SetNextWindowSize(dialogSize, ImGuiCond.Appearing);')
[System.IO.File]::WriteAllText($fileBrowserPath, $fileBrowser, [System.Text.UTF8Encoding]::new($false))

# ZIPs also work when dragged directly onto the game window.
$windowPath = Join-Path $vendor "UI/GameWindow.cs"
$window = [System.IO.File]::ReadAllText($windowPath)
$window = $window.Replace('if (extension is ".gb" or ".gbc" or ".sgb")', 'if (extension is ".gb" or ".gbc" or ".sgb" or ".zip")')
$window = $window.Replace('_emulator.LoadRom(path);', '_emulator.LoadRom(RomFileLoader.ResolveRomPath(path), path);')
$window = $window.Replace('ImGui.TextWrapped("Open a legally obtained .gb, .gbc, or .sgb game file to start playing.");', 'ImGui.TextWrapped("Open a .gb, .gbc, or .sgb game, or a ZIP archive that contains one.");')

# Keep the welcome panel centered in the game area below the taller two-row toolbar.
$oldWelcomeLayout = @'
            var size = new Vector2(
                Math.Min(620f, Math.Max(320f, viewport.Size.X - 36f)),
                Math.Min(390f, Math.Max(280f, viewport.Size.Y - 70f)));
            var position = viewport.Pos + new Vector2(
                Math.Max(12f, (viewport.Size.X - size.X) * 0.5f),
                Math.Max(42f, (viewport.Size.Y - size.Y) * 0.5f));
'@
$newWelcomeLayout = @'
            float availableWidth = Math.Max(220f, viewport.Size.X - 32f);
            float topInset = Toolbar.HeightPoints + 12f;
            float availableHeight = Math.Max(220f, viewport.Size.Y - topInset - 16f);
            var size = new Vector2(Math.Min(620f, availableWidth), Math.Min(390f, availableHeight));
            var position = viewport.Pos + new Vector2(
                Math.Max(12f, (viewport.Size.X - size.X) * 0.5f),
                topInset + Math.Max(0f, (availableHeight - size.Y) * 0.5f));
'@
$window = $window.Replace($oldWelcomeLayout, $newWelcomeLayout)
[System.IO.File]::WriteAllText($windowPath, $window, [System.Text.UTF8Encoding]::new($false))

# Command-line ROM loading follows the same ZIP-aware path as the in-app browser.
$program = [System.IO.File]::ReadAllText($programPath)
$program = $program.Replace('emulator.LoadRom(args[0]);', 'emulator.LoadRom(RomFileLoader.ResolveRomPath(args[0]), args[0]);')
[System.IO.File]::WriteAllText($programPath, $program, [System.Text.UTF8Encoding]::new($false))

# Reflow toolbar controls into two compact rows. The old single row exceeded the default 640px window,
# causing controls and the ROM/FPS text to collide.
$toolbarPath = Join-Path $vendor "UI/Toolbar.cs"
$toolbar = [System.IO.File]::ReadAllText($toolbarPath)
$toolbar = $toolbar.Replace('public const float HeightPoints = 34f;', 'public const float HeightPoints = 68f;')
$drawStart = $toolbar.IndexOf('        public void Draw(double fps)')
$drawEnd = $toolbar.IndexOf('        /// <summary>Toggles emulation', $drawStart)
if ($drawStart -lt 0 -or $drawEnd -lt 0) { throw "Could not find the toolbar Draw method to make its layout responsive." }
$newDraw = @'
        public void Draw(double fps)
        {
            var viewport = ImGui.GetMainViewport();
            ImGui.SetNextWindowPos(viewport.Pos);
            ImGui.SetNextWindowSize(new Vector2(viewport.Size.X, HeightPoints));

            const ImGuiWindowFlags flags =
                ImGuiWindowFlags.NoTitleBar | ImGuiWindowFlags.NoResize | ImGuiWindowFlags.NoMove |
                ImGuiWindowFlags.NoScrollbar | ImGuiWindowFlags.NoScrollWithMouse |
                ImGuiWindowFlags.NoCollapse | ImGuiWindowFlags.NoSavedSettings |
                ImGuiWindowFlags.NoBringToFrontOnFocus;

            ImGui.PushStyleVar(ImGuiStyleVar.WindowRounding, 0f);
            ImGui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 0f);
            ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, new Vector2(10f, 4f));
            ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, new Vector2(8f, 3f));
            ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing, new Vector2(6f, 3f));

            if (ImGui.Begin("##toolbar", flags))
            {
                CallbackButton("Open", OpenRomRequested);
                ImGui.SameLine();
                DrawRecentButton();
                ImGui.SameLine();
                DrawPlayPauseButton();
                ImGui.SameLine();
                DrawFrameAdvanceButton();
                ImGui.SameLine();
                CallbackButton("Reset", ResetRequested);
                ImGui.SameLine();
                DrawSpeedButton();
                ImGui.SameLine();
                CallbackButton("Settings", OpenSettingsRequested);

                ImGui.NewLine();

                DrawDebugButton();
                ImGui.SameLine();
                DrawStateButtons();
                ImGui.SameLine();
                DrawStatus(fps);
            }
            ImGui.End();

            ImGui.PopStyleVar(5);
        }

'@
$toolbar = $toolbar.Substring(0, $drawStart) + $newDraw + $toolbar.Substring($drawEnd)
$toolbar = $toolbar.Replace('ImGui.Button("Frame Adv")', 'ImGui.Button("Step")')
$toolbar = $toolbar.Replace('ImGui.Button(visible ? "Hide Debug" : "Show Debug")', 'ImGui.Button(visible ? "Hide Debug" : "Debug")')
$statusStart = $toolbar.IndexOf('        private void DrawStatus(double fps)')
$statusEnd = $toolbar.IndexOf('    }' + $newLine + '}', $statusStart)
if ($statusStart -lt 0 -or $statusEnd -lt 0) { throw "Could not find toolbar status method." }
$newStatus = @'
        private void DrawStatus(double fps)
        {
            string state = _emulator.IsPaused ? "PAUSED" : "running";
            int slot = StateManager?.CurrentSlot ?? 0;
            string turbo = (IsTurboActive?.Invoke() ?? false) ? "  TURBO" : "";
            string suffix = $"{fps:0} FPS  {state}  slot {slot}{turbo}";
            float availableWidth = ImGui.GetContentRegionAvail().X;
            float suffixWidth = ImGui.CalcTextSize(suffix).X;
            string name = _emulator.CurrentRomName;
            float nameWidth = Math.Max(0f, availableWidth - suffixWidth - 18f);

            while (name.Length > 4 && ImGui.CalcTextSize(name + " | ").X > nameWidth)
                name = name.Substring(0, name.Length - 1);

            if (name.Length < _emulator.CurrentRomName.Length && name.Length > 1)
                name = name.Substring(0, name.Length - 1) + "…";

            if (availableWidth > 20f)
                ImGui.TextDisabled($"{name} | {suffix}");
        }
'@
$toolbar = $toolbar.Substring(0, $statusStart) + $newStatus + $toolbar.Substring($statusEnd)
[System.IO.File]::WriteAllText($toolbarPath, $toolbar, [System.Text.UTF8Encoding]::new($false))

# Dialogs scale to the current window instead of extending beyond its edges.
$settingsPath = Join-Path $vendor "UI/SettingsDialog.cs"
$settings = [System.IO.File]::ReadAllText($settingsPath)
$settings = $settings.Replace(
    'ImGui.SetNextWindowPos(viewport.Pos + viewport.Size * 0.5f, ImGuiCond.Appearing, new Vector2(0.5f, 0.5f));' + $newLine + '            ImGui.SetNextWindowSize(new Vector2(520, 420), ImGuiCond.Appearing);',
    'var dialogSize = new Vector2(Math.Min(520f, Math.Max(420f, viewport.Size.X - 32f)), Math.Min(420f, Math.Max(320f, viewport.Size.Y - 76f)));' + $newLine + '            ImGui.SetNextWindowPos(viewport.Pos + viewport.Size * 0.5f, ImGuiCond.Appearing, new Vector2(0.5f, 0.5f));' + $newLine + '            ImGui.SetNextWindowSize(dialogSize, ImGuiCond.Appearing);')
[System.IO.File]::WriteAllText($settingsPath, $settings, [System.Text.UTF8Encoding]::new($false))

Write-Host "PocketGB ZIP ROM loading and responsive UI fixes prepared." -ForegroundColor Green


# Compatibility and performance hardening.
# Use a drift-resistant frame deadline instead of restarting a stopwatch every loop. The short final
# spin keeps timing precise without busy-waiting for the whole frame on low-power CPUs.
$programSource = @'
using GameboySharp;
using Serilog;
using Serilog.Events;
using System.Diagnostics;

public class Program
{
    public static void Main(string[] args)
    {
        Log.Logger = new LoggerConfiguration()
            .MinimumLevel.Information()
            .Enrich.FromLogContext()
            .WriteTo.Console(outputTemplate: "[{Timestamp:HH:mm:ss} {Level:u3}] {Message:lj}{NewLine}{Exception}", restrictedToMinimumLevel: LogEventLevel.Information)
            .WriteTo.File(
                path: "logs/pocketgb-.log",
                rollingInterval: RollingInterval.Day,
                retainedFileCountLimit: 7,
                shared: true,
                outputTemplate: "{Timestamp:yyyy-MM-dd HH:mm:ss.fff zzz} [{Level:u3}] {Message:lj}{NewLine}{Exception}")
            .CreateLogger();

        var config = ConfigStore.Load();

        Log.Information("Initializing PocketGB...");
        using var emulator = new Emulator(config);

        if (args.Length > 0)
        {
            try
            {
                emulator.LoadRom(RomFileLoader.ResolveRomPath(args[0]));
                config.AddRecentRom(args[0]);
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Failed to load game file at '{Path}'. Open another game from the toolbar.", args[0]);
            }
        }

        Log.Information("Creating windows...");
        using var gameWindow = new GameWindow(emulator, config);
        using var debugWindow = new DebugWindow(emulator);

        debugWindow.SilkWindow.IsVisible = false;
        gameWindow.Toolbar.IsDebugWindowVisible = () => debugWindow.SilkWindow.IsVisible;
        gameWindow.Toolbar.ToggleDebugWindow = () =>
            debugWindow.SilkWindow.IsVisible = !debugWindow.SilkWindow.IsVisible;

        bool shuttingDown = false;
        void ShutDownBothWindows()
        {
            if (shuttingDown) return;
            shuttingDown = true;
            gameWindow.SilkWindow.Close();
            debugWindow.SilkWindow.Close();
        }
        gameWindow.SilkWindow.Closing += ShutDownBothWindows;
        debugWindow.SilkWindow.Closing += ShutDownBothWindows;

        Log.Information("Starting main loop...");
        long nextFrameDeadline = Stopwatch.GetTimestamp();

        while (!gameWindow.SilkWindow.IsClosing && !debugWindow.SilkWindow.IsClosing)
        {
            gameWindow.SilkWindow.DoEvents();
            debugWindow.SilkWindow.DoEvents();

            gameWindow.SilkWindow.DoUpdate();
            emulator.RunFrame();

            // The debug view uploads many tile textures. Keep it completely out of the hot path
            // while hidden; only ask Silk to render it when the user has opened it.
            gameWindow.SilkWindow.DoRender();
            if (debugWindow.SilkWindow.IsVisible)
                debugWindow.SilkWindow.DoRender();

            if (gameWindow.TurboActive)
            {
                // Do not carry a stale normal-speed deadline into fast-forward mode.
                nextFrameDeadline = Stopwatch.GetTimestamp();
                continue;
            }

            double speed = Math.Max(0.1, config.General.SpeedMultiplier);
            long frameInterval = Math.Max(1L, (long)Math.Round(
                Stopwatch.Frequency / (GameboyConstants.FramesPerSecond * speed)));

            nextFrameDeadline += frameInterval;
            long now = Stopwatch.GetTimestamp();

            // If the machine fell several frames behind, drop the stale deadline rather than trying
            // to execute a burst of catch-up frames that makes input and audio feel worse.
            if (now - nextFrameDeadline > frameInterval * 3L)
            {
                nextFrameDeadline = now;
            }

            long remaining = nextFrameDeadline - now;
            if (remaining > Stopwatch.Frequency / 1000)
            {
                double remainingMs = remaining * 1000.0 / Stopwatch.Frequency;
                int coarseSleepMs = (int)Math.Floor(remainingMs - 1.0);
                if (coarseSleepMs > 0)
                    Thread.Sleep(coarseSleepMs);
            }

            // Only the final millisecond is a short spin; the rest of each frame is sleep-paced.
            while ((remaining = nextFrameDeadline - Stopwatch.GetTimestamp()) > 0)
                Thread.SpinWait(8);
        }

        Log.Information("Closing PocketGB.");
        ConfigStore.Save(config);
    }
}
'@
[System.IO.File]::WriteAllText($programPath, $programSource, [System.Text.UTF8Encoding]::new($false))

# Some OpenGL drivers emit non-fatal compiler diagnostics. A non-empty info log is not proof that
# compilation failed; inspect GL_COMPILE_STATUS and surface warnings without aborting the emulator.
$screenRendererPath = Join-Path $vendor "UI/ScreenRenderer.cs"
$screenRenderer = [System.IO.File]::ReadAllText($screenRendererPath)
$oldShaderCompile = @'
            string infoLog = _gl.GetShaderInfoLog(shader);
            if (!string.IsNullOrWhiteSpace(infoLog))
            {
                throw new Exception($"Error compiling {type}: {infoLog}");
            }
            return shader;
'@
$newShaderCompile = @'
            _gl.GetShader(shader, GLEnum.CompileStatus, out var compileStatus);
            string infoLog = _gl.GetShaderInfoLog(shader);
            if (compileStatus == 0)
            {
                _gl.DeleteShader(shader);
                throw new Exception($"Error compiling {type}: {infoLog}");
            }

            if (!string.IsNullOrWhiteSpace(infoLog))
            {
                Serilog.Log.Warning("OpenGL {ShaderType} shader compiler reported: {InfoLog}", type, infoLog);
            }

            return shader;
'@
if (-not $screenRenderer.Contains($oldShaderCompile)) { throw "Could not find the shader compile check in ScreenRenderer.cs." }
$screenRenderer = $screenRenderer.Replace($oldShaderCompile, $newShaderCompile)
$oldLinkFailure = @'
            if (status == 0)
            {
                throw new Exception($"Error linking shader program: {_gl.GetProgramInfoLog(program)}");
            }

            _gl.DeleteShader(vertexShader);
            _gl.DeleteShader(fragmentShader);
            return program;
'@
$newLinkFailure = @'
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
'@
if (-not $screenRenderer.Contains($oldLinkFailure)) { throw "Could not find the shader link check in ScreenRenderer.cs." }
$screenRenderer = $screenRenderer.Replace($oldLinkFailure, $newLinkFailure)
[System.IO.File]::WriteAllText($screenRendererPath, $screenRenderer, [System.Text.UTF8Encoding]::new($false))

# On small or highly scaled displays, preserve the full 160x144 image by allowing fractional
# downscaling when an integer scale would be smaller than 1x (instead of overflowing the toolbar).
$windowPath = Join-Path $vendor "UI/GameWindow.cs"
$window = [System.IO.File]::ReadAllText($windowPath)
$oldScale = 'scale = Math.Max(1f, MathF.Floor(scale));'
if (-not $window.Contains($oldScale)) { throw "Could not find the integer scaling clamp in GameWindow.cs." }
$window = $window.Replace($oldScale, 'scale = scale >= 1f ? MathF.Floor(scale) : scale;')
[System.IO.File]::WriteAllText($windowPath, $window, [System.Text.UTF8Encoding]::new($false))

# Add headless tests for ZIP ROM loading and cache invalidation. The source is generated at build
# time because the emulator core is pinned as a Git submodule.
$testsDirectory = Join-Path $vendor "GameboySharp.Tests"
if (Test-Path $testsDirectory) {
    $romLoaderTests = @'
using System.IO.Compression;
using GameboySharp;
using Xunit;

namespace GameboySharp.Tests;

public sealed class RomFileLoaderTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "PocketGB-RomTests", Guid.NewGuid().ToString("N"));

    public RomFileLoaderTests()
    {
        Directory.CreateDirectory(_root);
    }

    [Fact]
    public void ResolvesSupportedRomFromZip()
    {
        byte[] expected = { 0x01, 0x02, 0x03, 0x04 };
        string zip = CreateArchive(("games/title.gbc", expected));

        string resolved = RomFileLoader.ResolveRomPath(zip);

        Assert.Equal(expected, File.ReadAllBytes(resolved));
        Assert.EndsWith(".gbc", resolved, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void SelectsFirstRootRomInStableAlphabeticalOrder()
    {
        string zip = CreateArchive(
            ("zeta.gb", new byte[] { 0x09 }),
            ("alpha.gb", new byte[] { 0x01 }),
            ("folder/nested.gbc", new byte[] { 0x02 }));

        string resolved = RomFileLoader.ResolveRomPath(zip);

        Assert.Equal(new byte[] { 0x01 }, File.ReadAllBytes(resolved));
    }

    [Fact]
    public void RejectsZipWithoutSupportedRom()
    {
        string zip = CreateArchive(("readme.txt", new byte[] { 0x52 }));

        Assert.Throws<InvalidDataException>(() => RomFileLoader.ResolveRomPath(zip));
    }

    [Fact]
    public void InvalidatesCacheWhenArchiveBytesChange()
    {
        string zip = Path.Combine(_root, "replace-in-place.zip");
        WriteArchive(zip, ("game.gb", new byte[] { 0x01, 0x02, 0x03 }));
        string firstPath = RomFileLoader.ResolveRomPath(zip);

        WriteArchive(zip, ("game.gb", new byte[] { 0x04, 0x05, 0x06 }));
        string secondPath = RomFileLoader.ResolveRomPath(zip);

        Assert.NotEqual(firstPath, secondPath);
        Assert.Equal(new byte[] { 0x04, 0x05, 0x06 }, File.ReadAllBytes(secondPath));
    }

    private string CreateArchive(params (string Name, byte[] Data)[] entries)
    {
        string path = Path.Combine(_root, "test-" + Guid.NewGuid().ToString("N") + ".zip");
        WriteArchive(path, entries);
        return path;
    }

    private static void WriteArchive(string path, params (string Name, byte[] Data)[] entries)
    {
        if (File.Exists(path))
            File.Delete(path);

        using var archive = ZipFile.Open(path, ZipArchiveMode.Create);
        foreach (var item in entries)
        {
            var entry = archive.CreateEntry(item.Name, CompressionLevel.Optimal);
            using var output = entry.Open();
            output.Write(item.Data, 0, item.Data.Length);
        }
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_root))
                Directory.Delete(_root, recursive: true);
        }
        catch
        {
            // Test cleanup should not hide the actual assertion result.
        }
    }
}
'@
    $testPath = Join-Path $testsDirectory "RomFileLoaderTests.cs"
    [System.IO.File]::WriteAllText($testPath, $romLoaderTests, [System.Text.UTF8Encoding]::new($false))
}
Write-Host "PocketGB compatibility, frame pacing, graphics diagnostics and ROM tests prepared." -ForegroundColor Green


# Keep user save files beside the original archive for ZIP-launched games, not in the hidden cache.
$emulatorPath = Join-Path $vendor "Emulator.cs"
$emulatorSource = [System.IO.File]::ReadAllText($emulatorPath)
$emulatorSource = $emulatorSource.Replace(
    'public void LoadRom(string path)',
    'public void LoadRom(string path, string? saveIdentityPath = null)')
$emulatorSource = $emulatorSource.Replace(
    'CurrentRomPath = path;',
    'CurrentRomPath = string.IsNullOrWhiteSpace(saveIdentityPath) ? Path.GetFullPath(path) : Path.GetFullPath(saveIdentityPath);')
if (-not $emulatorSource.Contains('saveIdentityPath')) { throw "Could not add the original-file save path to Emulator.LoadRom." }
[System.IO.File]::WriteAllText($emulatorPath, $emulatorSource, [System.Text.UTF8Encoding]::new($false))

$windowSource = [System.IO.File]::ReadAllText($windowPath)
$windowSource = $windowSource.Replace(
    '_emulator.LoadRom(RomFileLoader.ResolveRomPath(path));',
    '_emulator.LoadRom(RomFileLoader.ResolveRomPath(path), path);')
if (-not $windowSource.Contains('_emulator.LoadRom(RomFileLoader.ResolveRomPath(path), path);')) {
    throw "Could not connect ZIP source paths to UI game loading."
}
[System.IO.File]::WriteAllText($windowPath, $windowSource, [System.Text.UTF8Encoding]::new($false))

$programFinal = [System.IO.File]::ReadAllText($programPath)
$programFinal = $programFinal.Replace(
    'emulator.LoadRom(RomFileLoader.ResolveRomPath(args[0]));',
    'emulator.LoadRom(RomFileLoader.ResolveRomPath(args[0]), args[0]);')
if (-not $programFinal.Contains('emulator.LoadRom(RomFileLoader.ResolveRomPath(args[0]), args[0]);')) {
    throw "Could not connect ZIP source paths to command-line game loading."
}
[System.IO.File]::WriteAllText($programPath, $programFinal, [System.Text.UTF8Encoding]::new($false))
Write-Host "ZIP games now keep battery saves and save states beside the original archive." -ForegroundColor Green

# Apply the optional PocketGB display, shader and graphics diagnostics layer.
& (Join-Path $PSScriptRoot "Prepare.DisplaySettings.ps1")
