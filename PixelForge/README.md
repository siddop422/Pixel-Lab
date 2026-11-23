# PixelForge 2.1.0 — Windows Desktop Image Editor

PixelForge is an offline-first Windows image editor built with C# and WPF. It uses built-in .NET APIs and has no third-party NuGet dependencies.

## Download and start

1. Open the [PixelForge 2.1.0 GitHub Release](https://github.com/siddop422/Pixel-Lab/releases/tag/v2.1.0).
2. Download PixelForge.exe for a direct launch, or download and extract PixelForge-Windows-x64.zip.
3. Double-click PixelForge.exe.

No terminal, Python, Visual Studio, or separate .NET installation is required. The release targets 64-bit Windows.

## Editing features

- Import PNG, JPEG, BMP and TIFF images, including drag-and-drop
- Multiple image layers with visibility toggles, reordering, rename, duplicate and delete
- Brush with adjustable size and color
- Transparent eraser
- Text insertion as an independent raster layer
- Crop selection applied consistently across all layers
- Brightness, contrast and saturation adjustments on the selected layer
- Undo and redo for brush, eraser, text, crop and adjustments
- Save and reopen editable .pfx projects
- Export the visible composite to PNG, JPEG or BMP at the document dimensions
- Zoom and fit view
- Custom accent, brush color, brush size and text size; preferences persist locally
- Keyboard shortcuts

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| Ctrl+O | Open images |
| Ctrl+Shift+O | Open PFX project |
| Ctrl+S | Save PFX project |
| Ctrl+E | Export image |
| Ctrl+Z / Ctrl+Y | Undo / redo |
| B / E / T / C | Brush / Eraser / Text / Crop |
| Delete | Remove selected layer |
| Ctrl+Up / Ctrl+Down | Reorder layer |

## Reliability and performance

- No third-party NuGet packages, embedded browser, telemetry or cloud service.
- Brush stamps reuse a dirty-region buffer instead of allocating a new region array on every mouse movement.
- Completed brush strokes reuse the prior immutable image as the undo snapshot and retain the completed writable bitmap directly, avoiding extra full-resolution history copies.
- The .pfx format is versioned. The application continues to read v2.0.0 project files.
- Project writes use a temporary file and replace the destination only after the archive has been completed and flushed.
- Project loading validates archive entries, canvas dimensions, PNG headers, layer counts and memory limits. It does not extract archive paths to disk.
- Export renders at original document dimensions, independently of editor zoom.
- All image processing stays on the local PC.

Large documents and many layers still require RAM. Project persistence applies safety limits to avoid opening archives that could exhaust memory. Actual performance depends on image dimensions and hardware.

## Build from source

Requirements: Windows 10/11 x64 and the .NET 10 SDK with WPF desktop support. Open PixelForge/PixelForge.csproj in Visual Studio and press F5. The GitHub Actions workflow builds Debug and Release, runs package-free functional smoke tests, then publishes a self-contained Windows x64 single-file executable.

## Current limitations

PixelForge is a growing editor, not a full Photoshop replacement. The brush and eraser are raster tools; text is stored as a raster layer rather than editable text metadata. PSD import/export, masks, blend modes, transform handles, advanced selection tools, blur/sharpen filters, and GPU-accelerated filters are not included in this release. The published application is not code-signed. Automated smoke tests run on Windows CI; manual GUI testing must be performed on a Windows desktop.