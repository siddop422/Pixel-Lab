using Microsoft.Win32;
using PixelForge.Models;
using PixelForge.Services;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace PixelForge;

public partial class MainWindow : Window, INotifyPropertyChanged
{
    private double _zoom = 1.0;
    private EditorLayer? _selectedLayer;

    public ObservableCollection<EditorLayer> Layers { get; } = new();

    public EditorLayer? SelectedLayer
    {
        get => _selectedLayer;
        set
        {
            _selectedLayer = value;
            OnPropertyChanged(nameof(SelectedLayer));
            SelectedLayerText.Text = value?.Name ?? "No layer selected";
        }
    }

    public MainWindow()
    {
        InitializeComponent();
        DataContext = this;
        Layers.CollectionChanged += (_, _) => RebuildCanvas();
        LayersList.SelectionChanged += (_, _) => SelectedLayer = LayersList.SelectedItem as EditorLayer;
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged(string name)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private void Open_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "Import image",
            Filter = "Image files|*.png;*.jpg;*.jpeg;*.bmp;*.tif;*.tiff|All files|*.*",
            Multiselect = true
        };

        if (dialog.ShowDialog() != true) return;

        foreach (var file in dialog.FileNames)
        {
            try
            {
                var bitmap = new BitmapImage();
                bitmap.BeginInit();
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.UriSource = new Uri(file);
                bitmap.EndInit();
                bitmap.Freeze();

                if (Layers.Count == 0)
                {
                    DocumentCanvas.Width = bitmap.PixelWidth;
                    DocumentCanvas.Height = bitmap.PixelHeight;
                    CanvasSizeText.Text = $"{bitmap.PixelWidth} × {bitmap.PixelHeight} px";
                }

                var layer = new EditorLayer(Path.GetFileNameWithoutExtension(file), bitmap);
                Layers.Insert(0, layer);
                LayersList.SelectedItem = layer;
                StatusText.Text = $"Imported {Path.GetFileName(file)}";
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Could not open this image.\n\n{ex.Message}", "PixelForge",
                    MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        if (Layers.Count > 0)
        {
            WelcomePanel.Visibility = Visibility.Collapsed;
            FitCanvas();
        }
    }

    private void RebuildCanvas()
    {
        DocumentCanvas.Children.Clear();
        foreach (var layer in Layers.Reverse())
        {
            var image = new Image
            {
                Source = layer.Image,
                Width = layer.Image.PixelWidth,
                Height = layer.Image.PixelHeight,
                Stretch = Stretch.Fill,
                Visibility = layer.IsVisible ? Visibility.Visible : Visibility.Collapsed,
                IsHitTestVisible = false
            };
            DocumentCanvas.Children.Add(image);
        }
    }

    private void Export_Click(object sender, RoutedEventArgs e)
    {
        if (Layers.Count == 0)
        {
            MessageBox.Show("Import an image before exporting.", "PixelForge",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        var dialog = new SaveFileDialog
        {
            Title = "Export image",
            Filter = "PNG image|*.png|JPEG image|*.jpg|Bitmap image|*.bmp",
            DefaultExt = ".png",
            FileName = "PixelForge-export.png"
        };

        if (dialog.ShowDialog() != true) return;

        try
        {
            var extension = Path.GetExtension(dialog.FileName).TrimStart('.');
            ImageExportService.Export(DocumentCanvas, dialog.FileName, extension);
            StatusText.Text = $"Exported {Path.GetFileName(dialog.FileName)}";
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Export failed.\n\n{ex.Message}", "PixelForge",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void Fit_Click(object sender, RoutedEventArgs e) => FitCanvas();

    private void FitCanvas()
    {
        if (DocumentCanvas.Width <= 0 || DocumentCanvas.Height <= 0) return;

        var availableWidth = Math.Max(100, CanvasScroll.ViewportWidth - 50);
        var availableHeight = Math.Max(100, CanvasScroll.ViewportHeight - 50);
        _zoom = Math.Min(availableWidth / DocumentCanvas.Width, availableHeight / DocumentCanvas.Height);
        _zoom = Math.Clamp(_zoom, 0.05, 1.0);
        ApplyZoom();
    }

    private void ZoomIn_Click(object sender, RoutedEventArgs e)
    {
        _zoom = Math.Min(4.0, _zoom * 1.2);
        ApplyZoom();
    }

    private void ZoomOut_Click(object sender, RoutedEventArgs e)
    {
        _zoom = Math.Max(0.05, _zoom / 1.2);
        ApplyZoom();
    }

    private void ApplyZoom()
    {
        if (DocumentCanvas.Width <= 0 || DocumentCanvas.Height <= 0) return;
        DocumentCanvas.LayoutTransform = new ScaleTransform(_zoom, _zoom);
        ZoomText.Text = $"{_zoom * 100:0}%";
    }
}
