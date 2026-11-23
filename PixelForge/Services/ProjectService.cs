using PixelForge.Models;
using System.IO;
using System.IO.Compression;
using System.Text.Json;
using System.Windows.Media.Imaging;

namespace PixelForge.Services;

public static class ProjectService
{
    public sealed class ProjectManifest
    {
        public int Width { get; set; }
        public int Height { get; set; }
        public List<ProjectLayer> Layers { get; set; } = new();
    }

    public sealed class ProjectLayer
    {
        public string Name { get; set; } = "Layer";
        public bool IsVisible { get; set; } = true;
        public string ImageFile { get; set; } = "";
    }

    public static void Save(string path, IEnumerable<EditorLayer> layers, int width, int height)
    {
        using var file = new FileStream(path, FileMode.Create, FileAccess.ReadWrite, FileShare.None);
        using var archive = new ZipArchive(file, ZipArchiveMode.Create);
        var manifest = new ProjectManifest { Width = width, Height = height };
        var index = 0;

        foreach (var layer in layers)
        {
            var imagePath = $"layers/layer_{index:000}.png";
            manifest.Layers.Add(new ProjectLayer
            {
                Name = layer.Name, IsVisible = layer.IsVisible, ImageFile = imagePath
            });

            var entry = archive.CreateEntry(imagePath, CompressionLevel.Optimal);
            using (var stream = entry.Open())
            {
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(layer.Image));
                encoder.Save(stream);
            }
            index++;
        }

        var manifestEntry = archive.CreateEntry("manifest.json", CompressionLevel.Optimal);
        using var manifestStream = manifestEntry.Open();
        JsonSerializer.Serialize(manifestStream, manifest, new JsonSerializerOptions
        {
            WriteIndented = true
        });
    }

    public static (int Width, int Height, List<EditorLayer> Layers) Load(string path)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var archive = new ZipArchive(file, ZipArchiveMode.Read);
        var manifestEntry = archive.GetEntry("manifest.json")
            ?? throw new InvalidDataException("This is not a PixelForge project file.");

        ProjectManifest manifest;
        using (var stream = manifestEntry.Open())
            manifest = JsonSerializer.Deserialize<ProjectManifest>(stream)
                ?? throw new InvalidDataException("The project manifest is invalid.");

        if (manifest.Width <= 0 || manifest.Height <= 0 ||
            manifest.Width > 30000 || manifest.Height > 30000)
            throw new InvalidDataException("The project canvas dimensions are invalid.");

        var layers = new List<EditorLayer>();
        foreach (var item in manifest.Layers)
        {
            var entry = archive.GetEntry(item.ImageFile)
                ?? throw new InvalidDataException($"Missing layer image: {item.ImageFile}");

            BitmapImage bitmap;
            using (var input = entry.Open())
            using (var memory = new MemoryStream())
            {
                input.CopyTo(memory);
                memory.Position = 0;
                bitmap = new BitmapImage();
                bitmap.BeginInit();
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.StreamSource = memory;
                bitmap.EndInit();
                bitmap.Freeze();
            }

            layers.Add(new EditorLayer(item.Name, bitmap) { IsVisible = item.IsVisible });
        }

        return (manifest.Width, manifest.Height, layers);
    }
}
