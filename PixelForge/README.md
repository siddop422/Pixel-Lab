# PixelForge — Windows Desktop Edition

PixelForge is a lightweight, offline-first Windows image editor built with C# and WPF. The app uses built-in .NET/WPF APIs and has no third-party NuGet dependencies.

## Start the app

End users do **not** need to open a terminal.

1. Download the latest `PixelForge-Windows-x64` artifact from the repository's **Actions → Build PixelForge (Windows)** workflow.
2. Extract `PixelForge-Windows-x64.zip`.
3. Double-click `PixelForge.exe`.

The build is self-contained for 64-bit Windows and includes the .NET runtime.

## Build from Visual Studio

- Windows 10/11, x64
- Visual Studio 2022 with the .NET desktop development workload
- .NET 10 SDK

Open `PixelForge.csproj` and press **F5** to run the development build. For a distributable EXE, use the `Windows-x64` publish profile in `Properties/PublishProfiles`.

## Working features

- Custom PixelForge logo and Windows application icon
- Import PNG, JPEG, BMP and TIFF images
- Drag-and-drop image importing
- Multiple image layers
- Live layer visibility toggles
- Move layers up/down and remove the selected layer
- Fit canvas, zoom in and zoom out
- Export composited layers as PNG, JPEG or BMP
- Export always uses the original document dimensions, not the current zoom
- Keyboard shortcuts: Ctrl+O (open), Ctrl+E (export), Delete (remove layer), Ctrl+Up/Down (reorder)
- Local-only workflow; imported images are not uploaded anywhere

## Performance notes

- No third-party packages or browser engine.
- WPF and .NET provide the UI and image codec support.
- Imported bitmaps are loaded once and frozen for safe rendering.
- Export composites the document directly at its original pixel dimensions.
- The automated Windows publish uses a self-contained single-file build.

Large, high-resolution images still require memory proportional to their pixel dimensions. For best performance on low-memory PCs, close other heavy applications and work with moderate-sized source images.

## Planned features

Brush and eraser tools, crop, text layers, selections, masks, adjustment layers, blend modes, project save/load, undo/redo, and PSD support are not implemented yet. The corresponding toolbar buttons are intentionally disabled until those tools work.

## Project structure

- `MainWindow.xaml` — editor workspace and panels
- `MainWindow.xaml.cs` — UI actions, import, layers, shortcuts and zoom
- `Models/EditorLayer.cs` — observable image-layer model
- `Services/ImageExportService.cs` — full-resolution layer compositing and export
- `Assets/` — app logo and Windows icon
