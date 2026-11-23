using PixelForge.Models;
using PixelForge.Services;
using System.IO.Compression;
using System.Text;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace PixelForge.SmokeTests;

internal static class Program
{
    [STAThread]
    private static int Main()
    {
        var temporaryDirectory = Path.Combine(Path.GetTempPath(), "PixelForge-SmokeTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporaryDirectory);

        try
        {
            TestBrushAndEraser();
            TestProjectRoundTrip(temporaryDirectory);
            TestLegacyProjectCompatibility(temporaryDirectory);
            TestUnsafeProjectRejection(temporaryDirectory);
            Console.WriteLine("All PixelForge smoke tests passed.");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception);
            return 1;
        }
        finally
        {
            try { Directory.Delete(temporaryDirectory, recursive: true); }
            catch { }
        }
    }

    private static void TestBrushAndEraser()
    {
        const int size = 8;
        var pixels = new byte[size * size * 4];
        var source = BitmapSource.Create(size, size, 96, 96, PixelFormats.Bgra32,
            null, pixels, size * 4);
        source.Freeze();
        var writable = ImageProcessingService.ToWriteable(source, pixels);
        var scratch = Array.Empty<byte>();

        scratch = ImageProcessingService.PaintCircle(writable, pixels, 4, 4, 2,
            Colors.Red, erase: false, regionBuffer: scratch);
        var painted = ImageProcessingService.GetBgraPixels(writable, out _);
        var center = (4 * size + 4) * 4;
        Assert(painted[center + 3] > 0 && painted[center + 2] > 0,
            "brush should paint a red center pixel");

        scratch = ImageProcessingService.PaintCircle(writable, pixels, 4, 4, 2,
            Colors.Transparent, erase: true, regionBuffer: scratch);
        var erased = ImageProcessingService.GetBgraPixels(writable, out _);
        Assert(erased[center + 3] == 0, "eraser should restore transparency");
        Assert(scratch.Length > 0, "dirty-region scratch buffer should be allocated and reusable");
        Console.WriteLine("PASS brush paint / transparent erase");
    }

    private static void TestProjectRoundTrip(string directory)
    {
        var pixels = new byte[4 * 4 * 4];
        for (var i = 0; i < pixels.Length; i += 4)
        {
            pixels[i] = 30;
            pixels[i + 1] = 80;
            pixels[i + 2] = 180;
            pixels[i + 3] = 255;
        }

        var image = BitmapSource.Create(4, 4, 96, 96, PixelFormats.Bgra32,
            null, pixels, 4 * 4);
        image.Freeze();

        var path = Path.Combine(directory, "roundtrip.pfx");
        ProjectService.Save(path,
        [
            new EditorLayer("Background", image),
            new EditorLayer("Hidden detail", image) { IsVisible = false }
        ], 4, 4);

        var loaded = ProjectService.Load(path);
        Assert(loaded.Width == 4 && loaded.Height == 4, "project canvas dimensions should round-trip");
        Assert(loaded.Layers.Count == 2, "project layer count should round-trip");
        Assert(loaded.Layers[0].Name == "Background", "layer names should round-trip");
        Assert(!loaded.Layers[1].IsVisible, "layer visibility should round-trip");

        ProjectService.Save(path, [new EditorLayer("Overwrite safely", image)], 4, 4);
        var replaced = ProjectService.Load(path);
        Assert(replaced.Layers.Count == 1 && replaced.Layers[0].Name == "Overwrite safely",
            "saving over an existing project should produce a readable replacement");
        Console.WriteLine("PASS PFX v2 save / reopen / overwrite");
    }

    private static void TestLegacyProjectCompatibility(string directory)
    {
        var pixels = new byte[2 * 2 * 4];
        var image = BitmapSource.Create(2, 2, 96, 96, PixelFormats.Bgra32,
            null, pixels, 2 * 4);
        image.Freeze();

        var path = Path.Combine(directory, "legacy-v1.pfx");
        using (var file = File.Create(path))
        using (var archive = new ZipArchive(file, ZipArchiveMode.Create))
        {
            var manifest = archive.CreateEntry("manifest.json");
            using (var writer = new StreamWriter(manifest.Open(), new UTF8Encoding(false)))
            {
                writer.Write("{\"Width\":2,\"Height\":2,\"Layers\":[{\"Name\":\"Legacy\",\"IsVisible\":true,\"ImageFile\":\"layers/layer_000.png\"}]}");
            }

            var layer = archive.CreateEntry("layers/layer_000.png");
            using var stream = layer.Open();
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(image));
            encoder.Save(stream);
        }

        var loaded = ProjectService.Load(path);
        Assert(loaded.Layers.Count == 1 && loaded.Layers[0].Name == "Legacy",
            "v1 projects should remain compatible");
        Console.WriteLine("PASS legacy PFX v1 compatibility");
    }

    private static void TestUnsafeProjectRejection(string directory)
    {
        var path = Path.Combine(directory, "unsafe.pfx");
        using (var file = File.Create(path))
        using (var archive = new ZipArchive(file, ZipArchiveMode.Create))
        {
            var manifest = archive.CreateEntry("manifest.json");
            using (var writer = new StreamWriter(manifest.Open(), new UTF8Encoding(false)))
            {
                writer.Write("{\"FormatVersion\":2,\"Width\":8,\"Height\":8,\"Layers\":[{\"Name\":\"Bad\",\"IsVisible\":true,\"ImageFile\":\"../outside.png\"}]}");
            }

            var badEntry = archive.CreateEntry("../outside.png");
            using var stream = badEntry.Open();
            stream.WriteByte(0);
        }

        AssertThrows<InvalidDataException>(() => ProjectService.Load(path),
            "unsafe archive paths should be rejected");
        Console.WriteLine("PASS unsafe PFX archive rejection");
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException("Assertion failed: " + message);
    }

    private static void AssertThrows<T>(Action action, string message) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ": " + message);
    }
}