using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Media.Imaging;

namespace PixelForge.Models;

public sealed class EditorLayer : INotifyPropertyChanged
{
    private bool _isVisible = true;
    private string _name;

    public EditorLayer(string name, BitmapSource image)
    {
        _name = name;
        Image = image;
    }

    public string Name
    {
        get => _name;
        set { _name = value; OnPropertyChanged(); }
    }

    public BitmapSource Image { get; }
    public bool IsVisible
    {
        get => _isVisible;
        set { _isVisible = value; OnPropertyChanged(); }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
