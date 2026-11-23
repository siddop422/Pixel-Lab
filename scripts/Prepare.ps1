$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$vendor = Join-Path $root "vendor\GameboySharp"
$windowPath = Join-Path $vendor "UI\GameWindow.cs"
$configPath = Join-Path $vendor "Config\ConfigStore.cs"
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
            string identity = fullPath + "|" +
                File.GetLastWriteTimeUtc(fullPath).Ticks + "|" +
                selected.FullName + "|" + selected.Length;
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
$fileBrowserPath = Join-Path $vendor "UI\FileBrowser.cs"
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
$windowPath = Join-Path $vendor "UI\GameWindow.cs"
$window = [System.IO.File]::ReadAllText($windowPath)
$window = $window.Replace('if (extension is ".gb" or ".gbc" or ".sgb")', 'if (extension is ".gb" or ".gbc" or ".sgb" or ".zip")')
$window = $window.Replace('_emulator.LoadRom(path);', '_emulator.LoadRom(RomFileLoader.ResolveRomPath(path));')
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
$program = $program.Replace('emulator.LoadRom(args[0]);', 'emulator.LoadRom(RomFileLoader.ResolveRomPath(args[0]));')
[System.IO.File]::WriteAllText($programPath, $program, [System.Text.UTF8Encoding]::new($false))

# Reflow toolbar controls into two compact rows. The old single row exceeded the default 640px window,
# causing controls and the ROM/FPS text to collide.
$toolbarPath = Join-Path $vendor "UI\Toolbar.cs"
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
$settingsPath = Join-Path $vendor "UI\SettingsDialog.cs"
$settings = [System.IO.File]::ReadAllText($settingsPath)
$settings = $settings.Replace(
    'ImGui.SetNextWindowPos(viewport.Pos + viewport.Size * 0.5f, ImGuiCond.Appearing, new Vector2(0.5f, 0.5f));' + $newLine + '            ImGui.SetNextWindowSize(new Vector2(520, 420), ImGuiCond.Appearing);',
    'var dialogSize = new Vector2(Math.Min(520f, Math.Max(420f, viewport.Size.X - 32f)), Math.Min(420f, Math.Max(320f, viewport.Size.Y - 76f)));' + $newLine + '            ImGui.SetNextWindowPos(viewport.Pos + viewport.Size * 0.5f, ImGuiCond.Appearing, new Vector2(0.5f, 0.5f));' + $newLine + '            ImGui.SetNextWindowSize(dialogSize, ImGuiCond.Appearing);')
[System.IO.File]::WriteAllText($settingsPath, $settings, [System.Text.UTF8Encoding]::new($false))

Write-Host "PocketGB ZIP ROM loading and responsive UI fixes prepared." -ForegroundColor Green
