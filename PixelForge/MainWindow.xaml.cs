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
using System.Windows.Shapes;

namespace PixelForge;

public partial class MainWindow : Window, INotifyPropertyChanged
{
    private enum EditingTool { Brush, Eraser, Text, Crop }
    private sealed record LayerImageState(EditorLayer Layer, BitmapSource Image);
    private sealed record HistoryEntry(
        string Name, List<LayerImageState> Before, List<LayerImageState> After,
        double BeforeWidth, double BeforeHeight, double AfterWidth, double AfterHeight, EditorLayer? AddedLayer = null);

    private readonly List<HistoryEntry> _history = new();
    private readonly EditorSettings _settings = SettingsService.Load();
    private int _historyPosition;
    private double _zoom = 1.0;
    private EditorLayer? _selectedLayer;
    private EditingTool _activeTool = EditingTool.Brush;

    private bool _painting;
    private EditorLayer? _strokeLayer;
    private WriteableBitmap? _paintBitmap;
    private byte[]? _paintPixels;
    private BitmapSource? _strokeBefore;
    private Point _lastPaintPoint;
    private Color _strokeColor;
    private double _strokeRadius;

    private Point _cropStart;
    private Rect _cropRect;
    private Rectangle? _cropOutline;

    public ObservableCollection<EditorLayer> Layers { get; } = new();

    public EditorLayer? SelectedLayer
    {
        get => _selectedLayer;
        set
        {
            if (ReferenceEquals(_selectedLayer, value)) return;
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

        BrushColorBox.Text = _settings.BrushColor;
        BrushSizeSlider.Value = Math.Clamp(_settings.BrushSize, 1, 120);
        TextSizeSlider.Value = Math.Clamp(_settings.TextSize, 10, 160);
        AccentColorBox.Text = _settings.AccentColor;
        ApplyAccentColor(_settings.AccentColor);
        SetTool(EditingTool.Brush);
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged(string name)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private void Layers_CollectionChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.OldItems is not null)
            foreach (EditorLayer layer in e.OldItems)
                layer.PropertyChanged -= Layer_PropertyChanged;

        if (e.NewItems is not null)
            foreach (EditorLayer layer in e.NewItems)
                layer.PropertyChanged += Layer_PropertyChanged;

        RebuildCanvas();
    }

    private void Layer_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (sender is not EditorLayer layer) return;

        foreach (var image in DocumentCanvas.Children.OfType<Image>())
        {
            if (!ReferenceEquals(image.Tag, layer)) continue;
            if (e.PropertyName == nameof(EditorLayer.IsVisible))
                image.Visibility = layer.IsVisible ? Visibility.Visible : Visibility.Collapsed;
            if (e.PropertyName == nameof(EditorLayer.Image))
                image.Source = layer.Image;
        }

        if (e.PropertyName == nameof(EditorLayer.Name) && ReferenceEquals(SelectedLayer, layer))
            SelectedLayerText.Text = layer.Name;
    }

    private void Open_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "Open images",
            Filter = "Image files|*.png;*.jpg;*.jpeg;*.bmp;*.tif;*.tiff|All files|*.*",
            Multiselect = true
        };
        if (dialog.ShowDialog() == true) ImportFiles(dialog.FileNames);
    }

    private void ImportFiles(IEnumerable<string> files)
    {
        var imported = 0;
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

                var layer = new EditorLayer(Path.GetFileNameWithoutExtension(file), bitmap);
                Layers.Insert(0, layer);
                LayersList.SelectedItem = layer;

                var currentWidth = double.IsFinite(DocumentCanvas.Width) ? DocumentCanvas.Width : 0;
                var currentHeight = double.IsFinite(DocumentCanvas.Height) ? DocumentCanvas.Height : 0;
                DocumentCanvas.Width = Math.Max(currentWidth, bitmap.PixelWidth);
                DocumentCanvas.Height = Math.Max(currentHeight, bitmap.PixelHeight);
                CanvasSizeText.Text = $"{DocumentCanvas.Width:0} × {DocumentCanvas.Height:0} px";
                StatusText.Text = $"Imported {Path.GetFileName(file)}";
                imported++;
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Could not open {Path.GetFileName(file)}.\n\n{ex.Message}",
                    "PixelForge", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        if (Layers.Count > 0)
        {
            WelcomePanel.Visibility = Visibility.Collapsed;
            if (imported > 0) FitCanvas();
        }
        ClearHistory();
    }

    private void Document_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop)
            ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private void Document_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] files) return;
        var supported = files.Where(file =>
            Path.GetExtension(file).ToLowerInvariant() is
                ".png" or ".jpg" or ".jpeg" or ".bmp" or ".tif" or ".tiff");
        ImportFiles(supported);
    }

    private void RebuildCanvas()
    {
        DocumentCanvas.Children.Clear();
        foreach (var layer in Layers.Reverse())
        {
            DocumentCanvas.Children.Add(new Image
            {
                Source = layer.Image,
                Width = layer.Image.PixelWidth,
                Height = layer.Image.PixelHeight,
                Stretch = Stretch.Fill,
                Visibility = layer.IsVisible ? Visibility.Visible : Visibility.Collapsed,
                IsHitTestVisible = false,
                Tag = layer
            });
        }
    }

    private void SetTool(EditingTool tool)
    {
        _activeTool = tool;
        RemoveCropOutline();

        BrushToolButton.Background = ToolBrush(tool == EditingTool.Brush);
        EraserToolButton.Background = ToolBrush(tool == EditingTool.Eraser);
        TextToolButton.Background = ToolBrush(tool == EditingTool.Text);
        CropToolButton.Background = ToolBrush(tool == EditingTool.Crop);

        StatusText.Text = tool switch
        {
            EditingTool.Brush => "Brush selected · Draw on the image",
            EditingTool.Eraser => "Eraser selected · Remove pixels from the selected layer",
            EditingTool.Text => "Text selected · Click the canvas to add a text layer",
            EditingTool.Crop => "Crop selected · Drag a region, then choose Apply crop",
            _ => "Ready"
        };
    }

    private static Brush ToolBrush(bool selected)
        => new SolidColorBrush(selected
            ? Color.FromRgb(81, 71, 165)
            : Color.FromRgb(41, 45, 55));

    private void BrushTool_Click(object sender, RoutedEventArgs e) => SetTool(EditingTool.Brush);
    private void EraserTool_Click(object sender, RoutedEventArgs e) => SetTool(EditingTool.Eraser);
    private void TextTool_Click(object sender, RoutedEventArgs e) => SetTool(EditingTool.Text);
    private void CropTool_Click(object sender, RoutedEventArgs e) => SetTool(EditingTool.Crop);

    private Color ReadBrushColor()
    {
        try
        {
            return (Color)ColorConverter.ConvertFromString(BrushColorBox.Text.Trim())!;
        }
        catch
        {
            MessageBox.Show("Enter a valid color such as #8B7CFF.", "PixelForge",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return Colors.MediumPurple;
        }
    }

    private void DocumentCanvas_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (Layers.Count == 0 || DocumentCanvas.Width <= 0 || DocumentCanvas.Height <= 0)
            return;

        var point = e.GetPosition(DocumentCanvas);
        if (point.X < 0 || point.Y < 0 ||
            point.X >= DocumentCanvas.Width || point.Y >= DocumentCanvas.Height)
            return;

        if (_activeTool == EditingTool.Text)
        {
            AddTextAt(point);
            e.Handled = true;
            return;
        }

        if (_activeTool == EditingTool.Crop)
        {
            _cropStart = point;
            _cropOutline = new Rectangle
            {
                Stroke = Brushes.White,
                StrokeThickness = 1.5,
                StrokeDashArray = new DoubleCollection { 5, 3 },
                Fill = new SolidColorBrush(Color.FromArgb(35, 139, 124, 255)),
                IsHitTestVisible = false
            };
            Canvas.SetLeft(_cropOutline, point.X);
            Canvas.SetTop(_cropOutline, point.Y);
            DocumentCanvas.Children.Add(_cropOutline);
            DocumentCanvas.CaptureMouse();
            e.Handled = true;
            return;
        }

        BeginPaint(point);
        e.Handled = true;
    }

    private void BeginPaint(Point point)
    {
        _strokeLayer = SelectedLayer ?? Layers.FirstOrDefault();
        if (_strokeLayer is null) return;
        _strokeLayer.IsVisible = true;
        SelectedLayer = _strokeLayer;
        LayersList.SelectedItem = _strokeLayer;

        _strokeBefore = ImageProcessingService.Clone(_strokeLayer.Image);
        _paintBitmap = ImageProcessingService.ToWriteable(_strokeLayer.Image);
        _paintPixels = ImageProcessingService.GetBgraPixels(_strokeLayer.Image, out _);
        _strokeLayer.Image = _paintBitmap;
        _strokeColor = ReadBrushColor();
        _strokeRadius = Math.Max(0.75, BrushSizeSlider.Value / 2.0);
        _painting = true;
        _lastPaintPoint = point;
        DocumentCanvas.CaptureMouse();
        PaintAt(point);
    }

    private void DocumentCanvas_MouseMove(object sender, MouseEventArgs e)
    {
        var point = e.GetPosition(DocumentCanvas);

        if (_painting && _paintBitmap is not null && _paintPixels is not null)
        {
            var dx = point.X - _lastPaintPoint.X;
            var dy = point.Y - _lastPaintPoint.Y;
            var distance = Math.Sqrt(dx * dx + dy * dy);
            var spacing = Math.Max(1.0, _strokeRadius * 0.35);
            var steps = Math.Max(1, (int)Math.Ceiling(distance / spacing));

            for (var i = 1; i <= steps; i++)
            {
                var t = (double)i / steps;
                PaintAt(new Point(_lastPaintPoint.X + dx * t,
                                  _lastPaintPoint.Y + dy * t));
            }
            _lastPaintPoint = point;
        }
        else if (_cropOutline is not null && DocumentCanvas.IsMouseCaptured)
        {
            var left = Math.Min(_cropStart.X, point.X);
            var top = Math.Min(_cropStart.Y, point.Y);
            Canvas.SetLeft(_cropOutline, left);
            Canvas.SetTop(_cropOutline, top);
            _cropOutline.Width = Math.Abs(point.X - _cropStart.X);
            _cropOutline.Height = Math.Abs(point.Y - _cropStart.Y);
        }
    }

    private void PaintAt(Point point)
    {
        if (_paintBitmap is null || _paintPixels is null) return;
        ImageProcessingService.PaintCircle(
            _paintBitmap, _paintPixels, point.X, point.Y,
            _strokeRadius, _strokeColor, _activeTool == EditingTool.Eraser);
    }

    private void DocumentCanvas_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (_painting)
        {
            _painting = false;
            DocumentCanvas.ReleaseMouseCapture();

            if (_strokeLayer is not null && _strokeBefore is not null)
                PushHistory(
                    _activeTool == EditingTool.Eraser ? "Erase" : "Brush",
                    new List<LayerImageState> { new(_strokeLayer, _strokeBefore) },
                    DocumentCanvas.Width, DocumentCanvas.Height);

            _strokeLayer = null;
            _paintBitmap = null;
            _paintPixels = null;
            _strokeBefore = null;
            StatusText.Text = "Stroke applied · Ctrl+Z to undo";
            return;
        }

        if (_cropOutline is not null)
        {
            DocumentCanvas.ReleaseMouseCapture();
            var point = e.GetPosition(DocumentCanvas);
            var left = Math.Max(0, Math.Min(_cropStart.X, point.X));
            var top = Math.Max(0, Math.Min(_cropStart.Y, point.Y));
            var right = Math.Min(DocumentCanvas.Width, Math.Max(_cropStart.X, point.X));
            var bottom = Math.Min(DocumentCanvas.Height, Math.Max(_cropStart.Y, point.Y));

            _cropRect = new Rect(left, top, Math.Max(0, right - left), Math.Max(0, bottom - top));
            ApplyCropButton.IsEnabled = _cropRect.Width >= 4 && _cropRect.Height >= 4;
            StatusText.Text = ApplyCropButton.IsEnabled
                ? $"Crop area: {(int)_cropRect.Width} × {(int)_cropRect.Height} · Click Apply crop"
                : "Crop area too small · Drag a larger selection";
        }
    }

    private void AddTextAt(Point point)
    {
        var text = PromptForText();
        if (string.IsNullOrWhiteSpace(text)) return;

        var width = (int)DocumentCanvas.Width;
        var height = (int)DocumentCanvas.Height;
        var bitmap = ImageProcessingService.CreateText(
            width, height, text, point, ReadBrushColor(),
            TextSizeSlider.Value, VisualTreeHelper.GetDpi(this).PixelsPerDip);

        var layer = new EditorLayer($"Text: {text[..Math.Min(text.Length, 18)]}", bitmap);
        Layers.Insert(0, layer);
        LayersList.SelectedItem = layer;
        PushHistory("Add text", new List<LayerImageState>(), width, height, addedLayer: layer);
        StatusText.Text = "Text layer added · Reorder it in Layers";
    }

    private string? PromptForText()
    {
        var dialog = new Window
        {
            Title = "Add text layer",
            Width = 420,
            Height = 190,
            ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = this,
            Background = new SolidColorBrush(Color.FromRgb(32, 35, 43))
        };

        var panel = new StackPanel { Margin = new Thickness(18) };
        panel.Children.Add(new TextBlock
        {
            Text = "Text to add",
            Foreground = Brushes.White,
            Margin = new Thickness(0, 0, 0, 8)
        });

        var input = new TextBox
        {
            Height = 34, FontSize = 14, Text = "Your text",
            Padding = new Thickness(6)
        };
        panel.Children.Add(input);

        var add = new Button
        {
            Content = "Add text layer", Width = 130, Height = 34,
            Margin = new Thickness(0, 14, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Right, IsDefault = true
        };
        add.Click += (_, _) =>
        {
            if (!string.IsNullOrWhiteSpace(input.Text))
                dialog.DialogResult = true;
        };
        panel.Children.Add(add);
        dialog.Content = panel;
        input.Focus();
        input.SelectAll();
        return dialog.ShowDialog() == true ? input.Text.Trim() : null;
    }

    private void ApplyCrop_Click(object sender, RoutedEventArgs e)
    {
        if (_cropRect.IsEmpty || Layers.Count == 0) return;

        var x = Math.Clamp((int)Math.Floor(_cropRect.X), 0, (int)DocumentCanvas.Width - 1);
        var y = Math.Clamp((int)Math.Floor(_cropRect.Y), 0, (int)DocumentCanvas.Height - 1);
        var right = Math.Clamp((int)Math.Ceiling(_cropRect.Right), x + 1, (int)DocumentCanvas.Width);
        var bottom = Math.Clamp((int)Math.Ceiling(_cropRect.Bottom), y + 1, (int)DocumentCanvas.Height);
        var width = right - x;
        var height = bottom - y;
        var beforeWidth = DocumentCanvas.Width;
        var beforeHeight = DocumentCanvas.Height;
        var before = CaptureLayerImages(Layers);

        foreach (var layer in Layers)
            layer.Image = ImageProcessingService.Crop(layer.Image, x, y, width, height);

        DocumentCanvas.Width = width;
        DocumentCanvas.Height = height;
        CanvasSizeText.Text = $"{width} × {height} px";
        RemoveCropOutline();
        PushHistory("Crop", before, beforeWidth, beforeHeight);
        FitCanvas();
        StatusText.Text = "Crop applied to all layers · Ctrl+Z to undo";
    }

    private void RemoveCropOutline()
    {
        if (_cropOutline is not null)
            DocumentCanvas.Children.Remove(_cropOutline);
        _cropOutline = null;
        _cropRect = Rect.Empty;
        ApplyCropButton.IsEnabled = false;
    }

    private void ApplyAdjustments_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedLayer is null)
        {
            MessageBox.Show("Select a layer first.", "PixelForge",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        var beforeWidth = DocumentCanvas.Width;
        var beforeHeight = DocumentCanvas.Height;
        var before = ImageProcessingService.Clone(SelectedLayer.Image);
        SelectedLayer.Image = ImageProcessingService.Adjust(
            SelectedLayer.Image, BrightnessSlider.Value,
            ContrastSlider.Value, SaturationSlider.Value);

        PushHistory("Adjustments",
            new List<LayerImageState> { new(SelectedLayer, before) },
            beforeWidth, beforeHeight);
        StatusText.Text = $"Adjustments applied to {SelectedLayer.Name}";
    }

    private void ResetAdjustments_Click(object sender, RoutedEventArgs e)
    {
        BrightnessSlider.Value = 0;
        ContrastSlider.Value = 0;
        SaturationSlider.Value = 100;
    }

    private void ApplyAccent_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var color = (Color)ColorConverter.ConvertFromString(AccentColorBox.Text.Trim())!;
            ApplyAccentColor(color.ToString());
            _settings.AccentColor = color.ToString();
            _settings.BrushColor = BrushColorBox.Text.Trim();
            _settings.BrushSize = BrushSizeSlider.Value;
            _settings.TextSize = TextSizeSlider.Value;
            SettingsService.Save(_settings);
            StatusText.Text = $"Accent color set to {color}";
        }
        catch
        {
            MessageBox.Show("Enter a valid color such as #8B7CFF.", "PixelForge",
                MessageBoxButton.OK, MessageBoxImage.Information);
        }
    }

    private void ApplyAccentColor(string value)
    {
        var color = (Color)ColorConverter.ConvertFromString(value)!;
        var brush = new SolidColorBrush(color);
        OpenImagesButton.Background = brush;
        WelcomeOpenButton.Background = brush;
        BrushToolButton.BorderBrush = brush;
        EraserToolButton.BorderBrush = brush;
        TextToolButton.BorderBrush = brush;
        CropToolButton.BorderBrush = brush;
    }

    private void Window_Closing(object? sender, CancelEventArgs e)
    {
        _settings.BrushColor = BrushColorBox.Text.Trim();
        _settings.BrushSize = BrushSizeSlider.Value;
        _settings.TextSize = TextSizeSlider.Value;
        _settings.AccentColor = AccentColorBox.Text.Trim();
        SettingsService.Save(_settings);
    }

    private void SaveProject_Click(object sender, RoutedEventArgs e)
    {
        if (Layers.Count == 0)
        {
            MessageBox.Show("Open an image before saving a project.", "PixelForge",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        var dialog = new SaveFileDialog
        {
            Title = "Save PixelForge project", Filter = "PixelForge project|*.pfx",
            DefaultExt = ".pfx", FileName = "MyArtwork.pfx"
        };
        if (dialog.ShowDialog() != true) return;

        try
        {
            ProjectService.Save(dialog.FileName, Layers,
                (int)DocumentCanvas.Width, (int)DocumentCanvas.Height);
            StatusText.Text = $"Project saved: {Path.GetFileName(dialog.FileName)}";
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Could not save the project.\n\n{ex.Message}",
                "PixelForge", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void OpenProject_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "Open PixelForge project", Filter = "PixelForge project|*.pfx"
        };
        if (dialog.ShowDialog() != true) return;

        try
        {
            var project = ProjectService.Load(dialog.FileName);
            Layers.Clear();
            foreach (var layer in project.Layers)
                Layers.Add(layer);

            DocumentCanvas.Width = project.Width;
            DocumentCanvas.Height = project.Height;
            CanvasSizeText.Text = $"{project.Width} × {project.Height} px";
            WelcomePanel.Visibility = Layers.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            LayersList.SelectedIndex = Layers.Count > 0 ? 0 : -1;
            ClearHistory();
            FitCanvas();
            StatusText.Text = $"Opened project: {Path.GetFileName(dialog.FileName)}";
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Could not open this project.\n\n{ex.Message}",
                "PixelForge", MessageBoxButton.OK, MessageBoxImage.Error);
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
            DefaultExt = ".png", FileName = "PixelForge-export.png"
        };
        if (dialog.ShowDialog() != true) return;

        try
        {
            var extension = Path.GetExtension(dialog.FileName).TrimStart('.');
            ImageExportService.Export(Layers,
                (int)DocumentCanvas.Width, (int)DocumentCanvas.Height,
                dialog.FileName, extension);
            StatusText.Text = $"Exported {Path.GetFileName(dialog.FileName)}";
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Export failed.\n\n{ex.Message}", "PixelForge",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private List<LayerImageState> CaptureLayerImages(IEnumerable<EditorLayer> layers)
        => layers.Select(layer =>
            new LayerImageState(layer, ImageProcessingService.Clone(layer.Image))).ToList();

    private void PushHistory(string name, List<LayerImageState> before,
        double beforeWidth, double beforeHeight, EditorLayer? addedLayer = null)
    {
        if (_historyPosition < _history.Count)
            _history.RemoveRange(_historyPosition, _history.Count - _historyPosition);

        var affected = before.Select(x => x.Layer).ToList();
        var after = CaptureLayerImages(affected);
        _history.Add(new HistoryEntry(name, before, after,
            beforeWidth, beforeHeight, DocumentCanvas.Width, DocumentCanvas.Height, addedLayer));

        const int historyLimit = 5;
        if (_history.Count > historyLimit) _history.RemoveAt(0);
        _historyPosition = _history.Count;
        UpdateHistoryButtons();
    }

    private void Undo_Click(object sender, RoutedEventArgs e)
    {
        if (_historyPosition <= 0) return;
        var entry = _history[--_historyPosition];
        if (entry.AddedLayer is not null) Layers.Remove(entry.AddedLayer);
        ApplyHistory(entry.Before, entry.BeforeWidth, entry.BeforeHeight);
        StatusText.Text = $"Undo: {entry.Name}";
        UpdateHistoryButtons();
    }

    private void Redo_Click(object sender, RoutedEventArgs e)
    {
        if (_historyPosition >= _history.Count) return;
        var entry = _history[_historyPosition++];
        if (entry.AddedLayer is not null && !Layers.Contains(entry.AddedLayer))
            Layers.Insert(0, entry.AddedLayer);
        ApplyHistory(entry.After, entry.AfterWidth, entry.AfterHeight);
        StatusText.Text = $"Redo: {entry.Name}";
        UpdateHistoryButtons();
    }

    private void ApplyHistory(List<LayerImageState> snapshots, double width, double height)
    {
        foreach (var snapshot in snapshots)
            if (Layers.Contains(snapshot.Layer))
                snapshot.Layer.Image = snapshot.Image;

        DocumentCanvas.Width = width;
        DocumentCanvas.Height = height;
        CanvasSizeText.Text = $"{width:0} × {height:0} px";
        FitCanvas();
    }

    private void ClearHistory()
    {
        _history.Clear();
        _historyPosition = 0;
        UpdateHistoryButtons();
    }

    private void UpdateHistoryButtons()
    {
        UndoButton.IsEnabled = _historyPosition > 0;
        RedoButton.IsEnabled = _historyPosition < _history.Count;
    }

    private void MoveUp_Click(object sender, RoutedEventArgs e) => MoveSelectedLayer(-1);
    private void MoveDown_Click(object sender, RoutedEventArgs e) => MoveSelectedLayer(1);

    private void MoveSelectedLayer(int offset)
    {
        if (SelectedLayer is null) return;
        var current = Layers.IndexOf(SelectedLayer);
        var target = current + offset;
        if (current < 0 || target < 0 || target >= Layers.Count) return;

        Layers.Move(current, target);
        LayersList.SelectedItem = SelectedLayer;
        LayersList.ScrollIntoView(SelectedLayer);
        StatusText.Text = $"Moved layer {SelectedLayer.Name}";
    }

    private void DeleteSelected_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedLayer is null) return;
        var removed = SelectedLayer;
        Layers.Remove(removed);
        SelectedLayer = null;
        ClearHistory();

        if (Layers.Count == 0)
        {
            DocumentCanvas.Width = 0;
            DocumentCanvas.Height = 0;
            DocumentCanvas.LayoutTransform = Transform.Identity;
            WelcomePanel.Visibility = Visibility.Visible;
            CanvasSizeText.Text = "—";
            ZoomText.Text = "100%";
            _zoom = 1;
        }
        else
        {
            LayersList.SelectedIndex = Math.Max(0, LayersList.SelectedIndex);
        }

        StatusText.Text = $"Removed layer {removed.Name}";
    }

    private void Fit_Click(object sender, RoutedEventArgs e) => FitCanvas();

    private void FitCanvas()
    {
        if (DocumentCanvas.Width <= 0 || DocumentCanvas.Height <= 0) return;
        var availableWidth = Math.Max(100, CanvasScroll.ViewportWidth - 50);
        var availableHeight = Math.Max(100, CanvasScroll.ViewportHeight - 50);
        _zoom = Math.Clamp(Math.Min(
            availableWidth / DocumentCanvas.Width,
            availableHeight / DocumentCanvas.Height), 0.05, 1.0);
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

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (Keyboard.FocusedElement is TextBox) return;
        var ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        var shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);

        if (ctrl)
        {
            switch (e.Key)
            {
                case Key.O when shift:
                    OpenProject_Click(sender, new RoutedEventArgs()); e.Handled = true; return;
                case Key.O:
                    Open_Click(sender, new RoutedEventArgs()); e.Handled = true; return;
                case Key.S:
                    SaveProject_Click(sender, new RoutedEventArgs()); e.Handled = true; return;
                case Key.E:
                    Export_Click(sender, new RoutedEventArgs()); e.Handled = true; return;
                case Key.Z:
                    Undo_Click(sender, new RoutedEventArgs()); e.Handled = true; return;
                case Key.Y:
                    Redo_Click(sender, new RoutedEventArgs()); e.Handled = true; return;
                case Key.Up:
                    MoveSelectedLayer(-1); e.Handled = true; return;
                case Key.Down:
                    MoveSelectedLayer(1); e.Handled = true; return;
            }
        }

        switch (e.Key)
        {
            case Key.B: SetTool(EditingTool.Brush); break;
            case Key.E: SetTool(EditingTool.Eraser); break;
            case Key.T: SetTool(EditingTool.Text); break;
            case Key.C: SetTool(EditingTool.Crop); break;
            case Key.Delete: DeleteSelected_Click(sender, new RoutedEventArgs()); break;
            default: return;
        }
        e.Handled = true;
    }
}