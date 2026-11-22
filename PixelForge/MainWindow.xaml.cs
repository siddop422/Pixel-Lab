using Microsoft.Win32;
using PixelForge.Models;
using PixelForge.Services;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
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
            if (ReferenceEquals(_selectedLayer, value))
                return;

            _selectedLayer = value;
            OnPropertyChanged(nameof(SelectedLayer));

            if (SelectedLayerText is not null)
                SelectedLayerText.Text = value?.Name ?? "No layer selected";
        }
    }

    public MainWindow()
    {
        InitializeComponent();
        DataContext = this;
        Layers.CollectionChanged += Layers_CollectionChanged;
        LayersList.SelectionChanged += (_, _) =>
            SelectedLayer = LayersList.SelectedItem as EditorLayer;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged(string name)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private void Layers_CollectionChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.OldItems is not null)
        {
            foreach (EditorLayer layer in e.OldItems)
                layer.PropertyChanged -= Layer_PropertyChanged;
        }

        if (e.NewItems is not null)
        {
            foreach (EditorLayer layer in e.NewItems)
                layer.PropertyChanged += Layer_PropertyChanged;
        }

        RebuildCanvas();
    }

    private void Layer_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (sender is not EditorLayer layer)
            return;

        if (e.PropertyName == nameof(EditorLayer.IsVisible))
        {
            foreach (var image in DocumentCanvas.Children.OfType<Image>())
            {
                if (ReferenceEquals(image.Tag, layer))
                    image.Visibility = layer.IsVisible ? Visibility.Visible : Visibility.Collapsed;
            }
        }

        if (e.PropertyName == nameof(EditorLayer.Name) &&
            ReferenceEquals(SelectedLayer, layer))
        {
            SelectedLayerText.Text = layer.Name;
        }
    }

    private void Open_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "Open images",
            Filter = "Image files|*.png;*.jpg;*.jpeg;*.bmp;*.tif;*.tiff|All files|*.*",
            Multiselect = true
        };

        if (dialog.ShowDialog() == true)
            ImportFiles(dialog.FileNames);
    }

    private void ImportFiles(IEnumerable<string> files)
    {
        var importedAny = false;

        foreach (var file in files.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                var bitmap = new BitmapImage();
                bitmap.BeginInit();
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.UriSource = new Uri(file, UriKind.Absolute);
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
                importedAny = true;
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    $"Could not open this image:\n\n{ex.Message}",
                    "PixelForge", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        if (Layers.Count > 0)
        {
            WelcomePanel.Visibility = Visibility.Collapsed;
            if (importedAny)
                FitCanvas();
        }
    }

    private void Document_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop)
            ? DragDropEffects.Copy
            : DragDropEffects.None;
        e.Handled = true;
    }

    private void Document_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] files)
            return;

        var supported = files.Where(file =>
        {
            var ext = Path.GetExtension(file).ToLowerInvariant();
            return ext is ".png" or ".jpg" or ".jpeg" or ".bmp" or ".tif" or ".tiff";
        });

        ImportFiles(supported);
    }

    private void RebuildCanvas()
    {
        DocumentCanvas.Children.Clear();

        // Index 0 is the top layer in the UI, so draw the collection in reverse order.
        foreach (var layer in Layers.Reverse())
        {
            var image = new Image
            {
                Source = layer.Image,
                Width = layer.Image.PixelWidth,
                Height = layer.Image.PixelHeight,
                Stretch = Stretch.Fill,
                Visibility = layer.IsVisible ? Visibility.Visible : Visibility.Collapsed,
                IsHitTestVisible = false,
                Tag = layer
            };

            DocumentCanvas.Children.Add(image);
        }
    }

    private void Export_Click(object sender, RoutedEventArgs e)
    {
        if (Layers.Count == 0 || DocumentCanvas.Width <= 0 || DocumentCanvas.Height <= 0)
        {
            MessageBox.Show("Open an image before exporting.", "PixelForge",
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

        if (dialog.ShowDialog() != true)
            return;

        try
        {
            var extension = Path.GetExtension(dialog.FileName).TrimStart('.');
            ImageExportService.Export(
                Layers, (int)DocumentCanvas.Width, (int)DocumentCanvas.Height,
                dialog.FileName, extension);

            StatusText.Text = $"Exported {Path.GetFileName(dialog.FileName)}";
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Export failed.\n\n{ex.Message}", "PixelForge",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void MoveUp_Click(object sender, RoutedEventArgs e) => MoveSelectedLayer(-1);
    private void MoveDown_Click(object sender, RoutedEventArgs e) => MoveSelectedLayer(1);

    private void MoveSelectedLayer(int offset)
    {
        if (SelectedLayer is null)
            return;

        var current = Layers.IndexOf(SelectedLayer);
        var target = current + offset;

        if (current < 0 || target < 0 || target >= Layers.Count)
            return;

        Layers.Move(current, target);
        LayersList.SelectedItem = SelectedLayer;
        LayersList.ScrollIntoView(SelectedLayer);
        StatusText.Text = $"Moved layer {SelectedLayer.Name}";
    }

    private void DeleteSelected_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedLayer is null)
            return;

        var removed = SelectedLayer;
        var oldIndex = Layers.IndexOf(removed);
        Layers.Remove(removed);
        SelectedLayer = null;

        if (Layers.Count == 0)
        {
            DocumentCanvas.Width = 0;
            DocumentCanvas.Height = 0;
            DocumentCanvas.LayoutTransform = Transform.Identity;
            WelcomePanel.Visibility = Visibility.Visible;
            CanvasSizeText.Text = "—";
            ZoomText.Text = "100%";
            _zoom = 1.0;
        }
        else
        {
            LayersList.SelectedIndex = Math.Min(oldIndex, Layers.Count - 1);
        }

        StatusText.Text = $"Removed layer {removed.Name}";
    }

    private void Fit_Click(object sender, RoutedEventArgs e) => FitCanvas();

    private void FitCanvas()
    {
        if (DocumentCanvas.Width <= 0 || DocumentCanvas.Height <= 0)
            return;

        var availableWidth = Math.Max(100, CanvasScroll.ViewportWidth - 50);
        var availableHeight = Math.Max(100, CanvasScroll.ViewportHeight - 50);
        _zoom = Math.Min(
            availableWidth / DocumentCanvas.Width,
            availableHeight / DocumentCanvas.Height);
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
        if (DocumentCanvas.Width <= 0 || DocumentCanvas.Height <= 0)
            return;

        DocumentCanvas.LayoutTransform = new ScaleTransform(_zoom, _zoom);
        ZoomText.Text = $"{_zoom * 100:0}%";
    }

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (Keyboard.Modifiers == ModifierKeys.Control)
        {
            switch (e.Key)
            {
                case Key.O:
                    Open_Click(sender, new RoutedEventArgs());
                    e.Handled = true;
                    return;
                case Key.E:
                    Export_Click(sender, new RoutedEventArgs());
                    e.Handled = true;
                    return;
                case Key.Up:
                    MoveSelectedLayer(-1);
                    e.Handled = true;
                    return;
                case Key.Down:
                    MoveSelectedLayer(1);
                    e.Handled = true;
                    return;
            }
        }

        if (e.Key == Key.Delete)
        {
            DeleteSelected_Click(sender, new RoutedEventArgs());
            e.Handled = true;
        }
    }
}
