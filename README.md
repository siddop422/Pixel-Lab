# Pixel-Lab

A lightweight project space for creative tools and experiments.

## PixelForge — Windows Desktop Image Editor

**PixelForge** is an offline-first Windows desktop image editor built with C# and WPF.

- [Open the PixelForge project](PixelForge/)
- [Read the setup and feature guide](PixelForge/README.md)

### Get the Windows EXE — no terminal required

1. Open the repository's [Actions](../../actions) tab.
2. Select **Build PixelForge (Windows)**.
3. Open the latest successful run.
4. Download the **PixelForge-Windows-x64** artifact and extract the ZIP.
5. Double-click **PixelForge.exe**.

The build workflow runs automatically when PixelForge source files change on `main`. The EXE is self-contained for 64-bit Windows and does not require users to install .NET.

### Current features

- Import PNG, JPEG, BMP and TIFF images, including drag-and-drop
- Multiple image layers with live visibility
- Reorder and remove layers
- Zoom and fit canvas
- Export composited images to PNG, JPEG or BMP at original document dimensions
- Custom logo and Windows app icon
- Keyboard shortcuts
- No third-party NuGet packages

Brush, eraser, crop, text, selections, adjustments, project save/load, undo/redo and PSD support remain on the roadmap.

> PixelForge is an early-stage editor. The Windows workflow builds the app, but it should still be tested on a real Windows PC before treating it as a stable release.
