using PixelForge.Models;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace PixelForge.Services;

public static class ImageExportService
{
    /// <summary>
    /// Composites visible layers at the document's original pixel size.
    /// The editor zoom and surrounding UI do not affect exported dimensions.
    /// </summary>
    public static void Export(
        IEnumerable<EditorLayer> layers,
        int documentWidth,
        int documentHeight,
        string path,
        string format)
    {
        if (documentWidth <= 0 || documentHeight <= 0)
            throw new InvalidOperationException("There is no document to export.");

        var isJpeg = format.Equals("jpg", StringComparison.OrdinalIgnoreCase) ||
                     format.Equals("jpeg", StringComparison.OrdinalIgnoreCase);

        var visual = new DrawingVisual();
        using (var drawing = visual.RenderOpen())
        {
            var bounds = new Rect(0, 0, documentWidth, documentHeight);

            // JPEG cannot store transparency, so use a white background for that format.
            if (isJpeg)
                drawing.DrawRectangle(Brushes.White, null, bounds);

            // The first item in the layer panel is the top layer; draw bottom-to-top.
            foreach (var layer in layers.Reverse())
            {
                if (!layer.IsVisible)
                    continue;

                drawing.DrawImage(
                    layer.Image,
                    new Rect(0, 0, layer.Image.PixelWidth, layer.Image.PixelHeight));
            }
        }

        var bitmap = new RenderTargetBitmap(
            documentWidth, documentHeight, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        bitmap.Freeze();

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
