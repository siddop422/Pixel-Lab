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
