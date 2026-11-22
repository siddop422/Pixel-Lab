# PixelForge — Windows Desktop Edition

PixelForge is an early WPF desktop photo-editor foundation. It runs locally and has no NuGet package dependencies.

## Requirements

- Windows 10/11
- .NET 8 SDK (Windows)
- Visual Studio 2022 with the **.NET desktop development** workload, or the .NET CLI

## Run

Open `PixelForge.csproj` in Visual Studio and press **F5**.

Or from PowerShell in this folder:

```powershell
dotnet restore
dotnet run
```

To publish a Windows executable:

```powershell
dotnet publish -c Release -r win-x64 --self-contained true /p:PublishSingleFile=true
```

The published executable will be under:

`bin\Release\net8.0-windows\win-x64\publish\`

## Included in this first implementation

- Dark desktop editor shell
- Import PNG, JPEG, BMP and TIFF images
- Import multiple images as stacked image layers
- Layer visibility toggles
- Canvas fit, zoom in and zoom out
- Export visible canvas to PNG, JPEG or BMP
- Local-only workflow

## Current limitations

This is the first working foundation, not a Photoshop replacement yet. Imported layers currently stack at the top-left and use their original pixel dimensions. Brush painting, erasing, crop, text layers, selections, masks, blend modes, project save/load, and undo/redo are planned next. PSD support is not included in this starter.

## Architecture

- `MainWindow.xaml` — desktop workspace and panels
- `MainWindow.xaml.cs` — UI actions and initial document/layer orchestration
- `Models/EditorLayer.cs` — observable image-layer model
- `Services/ImageExportService.cs` — raster export service

The project uses WPF and built-in .NET APIs only.
