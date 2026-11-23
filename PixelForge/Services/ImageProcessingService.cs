using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace PixelForge.Services;

public static class ImageProcessingService
{
    public static byte[] GetBgraPixels(BitmapSource source, out int stride)
    {
        ArgumentNullException.ThrowIfNull(source);
        var converted = new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
        converted.Freeze();
        stride = checked(converted.PixelWidth * 4);
        var pixels = new byte[checked(stride * converted.PixelHeight)];
        converted.CopyPixels(pixels, stride, 0);
        return pixels;
    }

    public static BitmapSource CreateBitmap(int width, int height, byte[] pixels, int stride)
    {
        if (width <= 0 || height <= 0 || stride < checked(width * 4) ||
            pixels.Length < checked(stride * height))
            throw new ArgumentOutOfRangeException(nameof(width), "The pixel buffer dimensions are invalid.");

        var bitmap = BitmapSource.Create(width, height, 96, 96,
            PixelFormats.Bgra32, null, pixels, stride);
        bitmap.Freeze();
        return bitmap;
    }

    public static BitmapSource Clone(BitmapSource source)
    {
        var pixels = GetBgraPixels(source, out var stride);
        return CreateBitmap(source.PixelWidth, source.PixelHeight, pixels, stride);
    }

    public static WriteableBitmap ToWriteable(BitmapSource source)
    {
        var pixels = GetBgraPixels(source, out _);
        return ToWriteable(source, pixels);
    }

    public static WriteableBitmap ToWriteable(BitmapSource source, byte[] pixels)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(pixels);
        var stride = checked(source.PixelWidth * 4);
        if (pixels.Length < checked(stride * source.PixelHeight))
            throw new ArgumentException("The BGRA buffer is smaller than the source image.", nameof(pixels));

        var bitmap = new WriteableBitmap(source.PixelWidth, source.PixelHeight,
            96, 96, PixelFormats.Bgra32, null);
        bitmap.WritePixels(new Int32Rect(0, 0, source.PixelWidth, source.PixelHeight),
            pixels, stride, 0);
        return bitmap;
    }

    /// <summary>
    /// Paints a soft-edged circle and updates only its dirty rectangle. The caller-owned
    /// scratch buffer is reused between brush stamps to avoid allocating on every mouse move.
    /// </summary>
    public static byte[] PaintCircle(WriteableBitmap bitmap, byte[] pixels,
        double centerX, double centerY, double radius, Color color, bool erase,
        byte[]? regionBuffer = null)
    {
        ArgumentNullException.ThrowIfNull(bitmap);
        ArgumentNullException.ThrowIfNull(pixels);

        var width = bitmap.PixelWidth;
        var height = bitmap.PixelHeight;
        var stride = checked(width * 4);
        if (width <= 0 || height <= 0 || pixels.Length < checked(stride * height))
            throw new ArgumentException("The brush pixel buffer is invalid.", nameof(pixels));

        var outer = Math.Max(0.75, radius);
        var extent = outer + 0.5;
        if (centerX + extent < 0 || centerY + extent < 0 ||
            centerX - extent >= width || centerY - extent >= height)
            return regionBuffer ?? Array.Empty<byte>();

        var left = Math.Clamp((int)Math.Floor(centerX - extent), 0, width - 1);
        var top = Math.Clamp((int)Math.Floor(centerY - extent), 0, height - 1);
        var right = Math.Clamp((int)Math.Ceiling(centerX + extent), 0, width - 1);
        var bottom = Math.Clamp((int)Math.Ceiling(centerY + extent), 0, height - 1);
        if (right < left || bottom < top) return regionBuffer ?? Array.Empty<byte>();

        var maxDistanceSquared = extent * extent;
        for (var y = top; y <= bottom; y++)
        {
            var dy = y + 0.5 - centerY;
            var row = y * stride;
            for (var x = left; x <= right; x++)
            {
                var dx = x + 0.5 - centerX;
                var distanceSquared = dx * dx + dy * dy;
                if (distanceSquared > maxDistanceSquared) continue;

                var coverage = Math.Clamp(extent - Math.Sqrt(distanceSquared), 0, 1);
                if (coverage <= 0) continue;

                var index = row + x * 4;
                var oldAlpha = pixels[index + 3] / 255.0;

                if (erase)
                {
                    var newAlpha = oldAlpha * (1.0 - coverage);
                    pixels[index + 3] = (byte)Math.Round(newAlpha * 255);
                    if (newAlpha <= 0.001)
                    {
                        pixels[index] = 0;
                        pixels[index + 1] = 0;
                        pixels[index + 2] = 0;
                    }
                }
                else
                {
                    var outAlpha = coverage + oldAlpha * (1.0 - coverage);
                    if (outAlpha <= 0) continue;
                    pixels[index] = Blend(color.B, pixels[index], oldAlpha, coverage, outAlpha);
                    pixels[index + 1] = Blend(color.G, pixels[index + 1], oldAlpha, coverage, outAlpha);
                    pixels[index + 2] = Blend(color.R, pixels[index + 2], oldAlpha, coverage, outAlpha);
                    pixels[index + 3] = (byte)Math.Round(outAlpha * 255);
                }
            }
        }

        var regionWidth = right - left + 1;
        var regionHeight = bottom - top + 1;
        var regionStride = checked(regionWidth * 4);
        var requiredLength = checked(regionStride * regionHeight);
        regionBuffer ??= Array.Empty<byte>();
        if (regionBuffer.Length < requiredLength)
            regionBuffer = new byte[requiredLength];

        for (var row = 0; row < regionHeight; row++)
            Buffer.BlockCopy(pixels, (top + row) * stride + left * 4,
                regionBuffer, row * regionStride, regionStride);

        bitmap.WritePixels(new Int32Rect(left, top, regionWidth, regionHeight),
            regionBuffer, regionStride, 0);
        return regionBuffer;
    }

    private static byte Blend(byte source, byte destination,
        double destinationAlpha, double sourceAlpha, double outputAlpha)
    {
        var value = (source * sourceAlpha +
                     destination * destinationAlpha * (1.0 - sourceAlpha)) / outputAlpha;
        return (byte)Math.Clamp((int)Math.Round(value), 0, 255);
    }

    public static BitmapSource Adjust(BitmapSource source,
        double brightness, double contrast, double saturation)
    {
        var pixels = GetBgraPixels(source, out var stride);
        var factor = 1.0 + Math.Clamp(contrast, -100, 100) / 100.0;
        var offset = Math.Clamp(brightness, -100, 100) * 2.55;
        var sat = Math.Clamp(saturation, 0, 200) / 100.0;

        for (var i = 0; i < pixels.Length; i += 4)
        {
            if (pixels[i + 3] == 0) continue;
            var b = pixels[i];
            var g = pixels[i + 1];
            var r = pixels[i + 2];
            var luminance = 0.0722 * b + 0.7152 * g + 0.2126 * r;

            b = Clamp(((b - 127.5) * factor + 127.5) + offset);
            g = Clamp(((g - 127.5) * factor + 127.5) + offset);
            r = Clamp(((r - 127.5) * factor + 127.5) + offset);

            pixels[i] = Clamp(luminance + (b - luminance) * sat);
            pixels[i + 1] = Clamp(luminance + (g - luminance) * sat);
            pixels[i + 2] = Clamp(luminance + (r - luminance) * sat);
        }

        return CreateBitmap(source.PixelWidth, source.PixelHeight, pixels, stride);
    }

    private static byte Clamp(double value)
        => (byte)Math.Clamp((int)Math.Round(value), 0, 255);

    public static BitmapSource Crop(BitmapSource source, int x, int y, int width, int height)
    {
        var visual = new DrawingVisual();
        using (var drawing = visual.RenderOpen())
            drawing.DrawImage(source, new Rect(-x, -y, source.PixelWidth, source.PixelHeight));

        var result = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        result.Render(visual);
        result.Freeze();
        return result;
    }

    public static BitmapSource CreateText(int width, int height, string text,
        Point position, Color color, double fontSize, double pixelsPerDip)
    {
        var visual = new DrawingVisual();
        using (var drawing = visual.RenderOpen())
        {
            var formatted = new FormattedText(text,
                System.Globalization.CultureInfo.CurrentCulture,
                FlowDirection.LeftToRight, new Typeface("Segoe UI Semibold"),
                fontSize, new SolidColorBrush(color), pixelsPerDip);
            drawing.DrawText(formatted, position);
        }

        var result = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        result.Render(visual);
        result.Freeze();
        return result;
    }
}