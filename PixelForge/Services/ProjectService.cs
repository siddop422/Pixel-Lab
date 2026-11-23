using System.IO;
using PixelForge.Models;
using System.Buffers.Binary;
using System.IO.Compression;
using System.Text.Json;
using System.Windows.Media.Imaging;

namespace PixelForge.Services;

/// <summary>
/// Versioned, bounded and atomic .pfx project persistence. Project archives are read
/// directly without extracting their contents to the filesystem.
/// </summary>
public static class ProjectService
{
    private const int CurrentFormatVersion = 2;
    private const int MaxCanvasDimension = 16000;
    private const long MaxCanvasPixels = 80_000_000;
    private const long MaxDecodedLayerPixels = 160_000_000;
    private const int MaxLayerCount = 64;
    private const long MaxProjectBytes = 512L * 1024 * 1024;
    private const long MaxManifestBytes = 2L * 1024 * 1024;
    private const long MaxLayerPngBytes = 256L * 1024 * 1024;
    private const long MaxTotalLayerBytes = 512L * 1024 * 1024;
    private static readonly byte[] PngSignature = [137, 80, 78, 71, 13, 10, 26, 10];

    public sealed class ProjectManifest
    {
        // Version 1 is the default so v2.0.0 manifests, which had no version property, remain readable.
        public int FormatVersion { get; set; } = 1;
        public int Width { get; set; }
        public int Height { get; set; }
        public List<ProjectLayer>? Layers { get; set; } = new();
    }

    public sealed class ProjectLayer
    {
        public string? Name { get; set; } = "Layer";
        public bool IsVisible { get; set; } = true;
        public string? ImageFile { get; set; } = "";
    }

    public static void Save(string path, IEnumerable<EditorLayer> layers, int width, int height)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        ArgumentNullException.ThrowIfNull(layers);
        ValidateCanvas(width, height);

        var layerList = layers.ToList();
        if (layerList.Count == 0 || layerList.Count > MaxLayerCount)
            throw new InvalidDataException($"A project must contain between 1 and {MaxLayerCount} layers.");

        long decodedPixels = 0;
        foreach (var layer in layerList)
        {
            if (layer.Image.PixelWidth <= 0 || layer.Image.PixelHeight <= 0 ||
                layer.Image.PixelWidth > width || layer.Image.PixelHeight > height)
                throw new InvalidDataException("A layer image does not fit within the document canvas.");

            decodedPixels = checked(decodedPixels + (long)layer.Image.PixelWidth * layer.Image.PixelHeight);
            if (decodedPixels > MaxDecodedLayerPixels)
                throw new InvalidDataException("The combined layer dimensions are too large for a safe project.");
        }

        var manifest = new ProjectManifest
        {
            FormatVersion = CurrentFormatVersion,
            Width = width,
            Height = height,
            Layers = new List<ProjectLayer>()
        };

        var fullPath = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(fullPath)
            ?? throw new InvalidOperationException("The project destination is invalid.");
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(directory,
            $".{Path.GetFileName(fullPath)}.{Guid.NewGuid():N}.tmp");

        try
        {
            using (var file = new FileStream(temporaryPath, FileMode.CreateNew,
                       FileAccess.ReadWrite, FileShare.None, 64 * 1024, FileOptions.WriteThrough))
            {
                using (var archive = new ZipArchive(file, ZipArchiveMode.Create, leaveOpen: true))
                {
                    for (var index = 0; index < layerList.Count; index++)
                    {
                        var layer = layerList[index];
                        var imagePath = $"layers/layer_{index:000}.png";
                        var layerName = layer.Name ?? "Layer";
                        manifest.Layers.Add(new ProjectLayer
                        {
                            Name = layerName[..Math.Min(layerName.Length, 256)],
                            IsVisible = layer.IsVisible,
                            ImageFile = imagePath
                        });

                        var entry = archive.CreateEntry(imagePath, CompressionLevel.Optimal);
                        using var output = entry.Open();
                        using var encodedPng = new MemoryStream();
                        var encoder = new PngBitmapEncoder();
                        encoder.Frames.Add(BitmapFrame.Create(layer.Image));
                        encoder.Save(encodedPng);
                        encodedPng.Position = 0;
                        encodedPng.CopyTo(output);
                    }

                    var manifestEntry = archive.CreateEntry("manifest.json", CompressionLevel.Optimal);
                    using var manifestStream = manifestEntry.Open();
                    JsonSerializer.Serialize(manifestStream, manifest, new JsonSerializerOptions
                    {
                        WriteIndented = true
                    });
                }

                file.Flush(flushToDisk: true);
            }

            // The archive is complete and flushed before replacing the target.
            // A failed encode leaves the previous project file untouched.
            File.Move(temporaryPath, fullPath, overwrite: true);
        }
        finally
        {
            try
            {
                if (File.Exists(temporaryPath))
                    File.Delete(temporaryPath);
            }
            catch
            {
                // Cleanup must not hide the original save error.
            }
        }
    }

    public static (int Width, int Height, List<EditorLayer> Layers) Load(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        var fileInfo = new FileInfo(path);
        if (!fileInfo.Exists)
            throw new FileNotFoundException("The PixelForge project was not found.", path);
        if (fileInfo.Length <= 0 || fileInfo.Length > MaxProjectBytes)
            throw new InvalidDataException("The project file is empty or exceeds the safe size limit.");

        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var archive = new ZipArchive(file, ZipArchiveMode.Read, leaveOpen: false);

        var manifestEntry = archive.GetEntry("manifest.json")
            ?? throw new InvalidDataException("This is not a PixelForge project file.");
        if (manifestEntry.Length <= 0 || manifestEntry.Length > MaxManifestBytes)
            throw new InvalidDataException("The project manifest is too large or empty.");

        ProjectManifest manifest;
        using (var stream = manifestEntry.Open())
        {
            manifest = JsonSerializer.Deserialize<ProjectManifest>(stream, new JsonSerializerOptions
            {
                MaxDepth = 32
            }) ?? throw new InvalidDataException("The project manifest is invalid.");
        }

        if (manifest.FormatVersion < 1 || manifest.FormatVersion > CurrentFormatVersion)
            throw new InvalidDataException($"Project format version {manifest.FormatVersion} is not supported.");
        ValidateCanvas(manifest.Width, manifest.Height);

        var projectLayers = manifest.Layers;
        if (projectLayers is null || projectLayers.Count == 0 || projectLayers.Count > MaxLayerCount)
            throw new InvalidDataException("The project layer list is missing or exceeds the safe layer limit.");

        if (archive.Entries.Count != projectLayers.Count + 1)
            throw new InvalidDataException("The project archive contains unexpected or duplicate entries.");

        var expectedEntries = new HashSet<string>(StringComparer.Ordinal) { "manifest.json" };
        long totalPngBytes = 0;
        long totalDecodedPixels = 0;
        var layers = new List<EditorLayer>(projectLayers.Count);

        for (var index = 0; index < projectLayers.Count; index++)
        {
            var item = projectLayers[index];
            var expectedName = $"layers/layer_{index:000}.png";
            if (!string.Equals(item.ImageFile, expectedName, StringComparison.Ordinal))
                throw new InvalidDataException("The project contains an invalid layer image path.");
            if (!expectedEntries.Add(expectedName))
                throw new InvalidDataException("The project contains duplicate layer image paths.");

            var layerName = item.Name?.Trim();
            if (string.IsNullOrWhiteSpace(layerName) || layerName.Length > 256)
                throw new InvalidDataException("A layer name is invalid.");

            var entry = archive.GetEntry(expectedName)
                ?? throw new InvalidDataException($"Missing layer image: {expectedName}");
            if (entry.Length <= 0 || entry.Length > MaxLayerPngBytes)
                throw new InvalidDataException($"Layer image {expectedName} exceeds the safe size limit.");

            totalPngBytes = checked(totalPngBytes + entry.Length);
            if (totalPngBytes > MaxTotalLayerBytes)
                throw new InvalidDataException("The combined layer image data exceeds the safe size limit.");

            using var input = entry.Open();
            using var imageData = ReadBounded(input, MaxLayerPngBytes);
            var dimensions = ReadPngDimensions(imageData);
            if (dimensions.Width > manifest.Width || dimensions.Height > manifest.Height)
                throw new InvalidDataException("A layer image is larger than the document canvas.");

            totalDecodedPixels = checked(totalDecodedPixels + (long)dimensions.Width * dimensions.Height);
            if (totalDecodedPixels > MaxDecodedLayerPixels)
                throw new InvalidDataException("The project would require too much memory to open safely.");

            imageData.Position = 0;
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.StreamSource = imageData;
            bitmap.EndInit();
            bitmap.Freeze();

            if (bitmap.PixelWidth != dimensions.Width || bitmap.PixelHeight != dimensions.Height)
                throw new InvalidDataException("A layer image has inconsistent dimensions.");

            layers.Add(new EditorLayer(layerName, bitmap) { IsVisible = item.IsVisible });
        }

        foreach (var entry in archive.Entries)
        {
            if (!expectedEntries.Contains(entry.FullName))
                throw new InvalidDataException("The project archive contains an unexpected entry.");
        }

        return (manifest.Width, manifest.Height, layers);
    }

    private static void ValidateCanvas(int width, int height)
    {
        if (width <= 0 || height <= 0 ||
            width > MaxCanvasDimension || height > MaxCanvasDimension ||
            (long)width * height > MaxCanvasPixels)
            throw new InvalidDataException("The project canvas dimensions exceed the safe limits.");
    }

    private static MemoryStream ReadBounded(Stream input, long maximumBytes)
    {
        var output = new MemoryStream();
        var buffer = new byte[64 * 1024];
        int read;
        while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
        {
            if (output.Length + read > maximumBytes)
                throw new InvalidDataException("A layer image expands beyond the safe size limit.");
            output.Write(buffer, 0, read);
        }

        output.Position = 0;
        return output;
    }

    private static (int Width, int Height) ReadPngDimensions(Stream imageData)
    {
        Span<byte> header = stackalloc byte[24];
        imageData.ReadExactly(header);
        if (!header[..8].SequenceEqual(PngSignature) ||
            !header.Slice(12, 4).SequenceEqual("IHDR"u8))
            throw new InvalidDataException("A project layer is not a valid PNG image.");

        var width = BinaryPrimitives.ReadUInt32BigEndian(header.Slice(16, 4));
        var height = BinaryPrimitives.ReadUInt32BigEndian(header.Slice(20, 4));
        if (width == 0 || height == 0 ||
            width > MaxCanvasDimension || height > MaxCanvasDimension ||
            (long)width * height > MaxCanvasPixels)
            throw new InvalidDataException("A layer image has unsafe dimensions.");

        return ((int)width, (int)height);
    }
}