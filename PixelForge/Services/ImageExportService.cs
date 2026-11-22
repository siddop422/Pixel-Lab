using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace PixelForge.Services;

public static class ImageExportService
{
    public static void Export(FrameworkElement surface, string path, string format)
    {
        if (surface.ActualWidth <= 0 || surface.ActualHeight <= 0)
            throw new InvalidOperationException("There is no document to export.");

        var width = Math.Max(1, (int)Math.Ceiling(surface.ActualWidth));
        var height = Math.Max(1, (int)Math.Ceiling(surface.ActualHeight));
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(surface);

        BitmapEncoder encoder = format.ToLowerInvariant() switch
        {
            "jpg" or "jpeg" => new JpegBitmapEncoder { QualityLevel = 95 },
            "bmp" => new BmpBitmapEncoder(),
            _ => new PngBitmapEncoder()
        };
        encoder.Frames.Add(BitmapFrame.Create(bitmap));

        using var stream = File.Create(path);
        encoder.Save(stream);
    }
}
