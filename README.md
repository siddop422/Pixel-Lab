# Pixel-Lab

A lightweight modern, vibe-coded Photoshop alternative project space.

## PixelForge — Windows Desktop Edition

The repository now includes **PixelForge**, an offline-first Windows desktop photo-editor starter built with C# and WPF.

Project source: [PixelForge/](PixelForge/)

### Included in the first implementation

- Import PNG, JPEG, BMP and TIFF images
- Stack multiple images as layers
- Toggle layer visibility
- Fit canvas, zoom in and zoom out
- Export to PNG, JPEG and BMP
- No third-party NuGet packages

### Run on Windows

Requirements: Windows 10/11 and the .NET 8 SDK with Windows desktop development support.

```powershell
cd PixelForge
dotnet restore
dotnet run
```

See [PixelForge/README.md](PixelForge/README.md) for build and publishing instructions.

### Roadmap

Brush and eraser tools, crop, text layers, layer reordering, adjustments, project save/load, and undo/redo are planned.

> This is an early starter implementation and has not yet been validated by a Windows build.
