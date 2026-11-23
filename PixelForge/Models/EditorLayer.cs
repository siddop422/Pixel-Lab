using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Media.Imaging;

namespace PixelForge.Models;

public sealed class EditorLayer : INotifyPropertyChanged
{
    private bool _isVisible = true;
    private string _name;
    private BitmapSource _image;

    public EditorLayer(string name, BitmapSource image)
    {
        _name = name;
        _image = image;
    }

    public string Name
    {
        get => _name;
        set { if (_name == value) return; _name = value; OnPropertyChanged(); }
    }

    public BitmapSource Image
    {
        get => _image;
        set { if (ReferenceEquals(_image, value)) return; _image = value; OnPropertyChanged(); }
    }

    public bool IsVisible
    {
        get => _isVisible;
        set { if (_isVisible == value) return; _isVisible = value; OnPropertyChanged(); }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
