# PixelForge 2.0 — Windows Desktop Image Editor

PixelForge is an offline-first Windows image editor built with C# and WPF. It uses built-in .NET APIs and has no third-party NuGet packages.

## Download and start

1. Open the PixelForge v2.0.0 Release.
2. Download PixelForge.exe (or the ZIP if preferred).
3. If you downloaded the ZIP, extract it.
4. Double-click PixelForge.exe.

No terminal, Python, Visual Studio, or separate .NET installation is required. This release targets 64-bit Windows.

## Editing features

- Import PNG, JPEG, BMP and TIFF images
- Drag-and-drop importing
- Multiple image layers with live visibility
- Move layers up/down and delete a layer
- Brush with adjustable size and color
- Eraser with transparent pixel erasing
- Text tool that creates an independent text layer
- Crop tool that crops every layer together
- Brightness, contrast and saturation adjustments on the selected layer
- Undo and redo for brush, eraser, text, crop and adjustments (last five edits)
- Save and reopen editable PFX projects
- Export the visible composite to PNG, JPEG or BMP at original canvas dimensions
- Zoom and fit view
- Custom accent color, brush color, brush size and text size; settings persist locally
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

## Performance and privacy

- No third-party NuGet packages, embedded browser or cloud service.
- Images are decoded once and frozen for WPF rendering.
- Brush strokes update only the affected pixel region.
- Undo history is limited to five edit operations to constrain memory use.
- Export renders at original document pixel dimensions, independently of editor zoom.
- Project files are ZIP containers containing a JSON manifest and PNG layer images.
- All image processing stays on the local PC.

Very large images still consume substantial RAM. On 4 GB systems, use fewer moderate-sized layers and close other memory-heavy applications.

## Build from source

Requirements: Windows 10/11 x64 and the .NET 10 SDK with WPF desktop support. Open PixelForge.csproj in Visual Studio and press F5. The GitHub Actions workflow publishes a self-contained single-file EXE and attaches it to the GitHub Release.

## Current limitations

PixelForge is a growing editor, not a full Photoshop replacement. PSD import/export, masks, blend modes, transform handles, curves, selection feathering and GPU-accelerated filters are not included in v2.0.
