using System.IO;
using System.Text.Json;

namespace PixelForge.Services;

public sealed class EditorSettings
{
    public string AccentColor { get; set; } = "#8B7CFF";
    public string BrushColor { get; set; } = "#8B7CFF";
    public double BrushSize { get; set; } = 18;
    public double TextSize { get; set; } = 44;
}

public static class SettingsService
{
    private static readonly string SettingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PixelForge", "settings.json");

    public static EditorSettings Load()
    {
        try
        {
            if (!File.Exists(SettingsPath)) return new EditorSettings();
            return JsonSerializer.Deserialize<EditorSettings>(File.ReadAllText(SettingsPath))
                ?? new EditorSettings();
        }
        catch { return new EditorSettings(); }
    }

    public static void Save(EditorSettings settings)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(settings,
                new JsonSerializerOptions { WriteIndented = true }));
        }
        catch
        {
            // User preferences are optional; failing to save them must not block editing.
        }
    }
}
