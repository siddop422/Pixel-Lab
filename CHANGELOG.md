# Changelog

## 2.1.0 — Performance & Editing Upgrade

- Reworked brush stroke setup to convert the source image to BGRA once rather than cloning it separately for undo, writable rendering and pixel editing.
- Reused dirty-region scratch memory across brush stamps instead of allocating a temporary byte array for each stamp.
- Reduced brush distance calculations by checking squared distance before calculating the square root.
- Kept completed brush images directly in history because each subsequent stroke creates a new writable bitmap; this avoids extra full-resolution after-state snapshots.
- Added Rename and Duplicate actions to the layer panel.
- Added a versioned .pfx manifest while keeping v2.0.0 project files readable.
- Made project saving temporary-file based and replaced the target only after the archive is complete and flushed.
- Added archive entry, canvas size, layer count, PNG header, file size and cumulative decoded-pixel validation. Project loading never extracts paths to disk.
- Added package-free Windows smoke tests for brush/eraser pixels, PFX round-trip/overwrite, legacy compatibility and unsafe archive rejection.
- Reworked the GitHub Actions workflow so normal pushes and pull requests build and test without touching the existing v2.0.0 release. v2.1.0 is published only by an explicit release dispatch or a dedicated release commit message.
- Added ZIP extraction and byte-for-byte SHA-256 verification to the release packaging step.


### CI verification (2026-11-23)

- Windows x64 Debug build: passed with 0 warnings and 0 errors.
- Windows x64 Release build: passed with 0 warnings and 0 errors.
- Automated smoke tests: brush/eraser, project save/reopen/overwrite, v2.0 project compatibility and unsafe archive rejection passed.
- Self-contained single-file EXE publish: passed.
- ZIP extraction and byte-for-byte SHA-256 verification: passed.
- The application GUI was not manually tested on a physical Windows desktop.

### Still not included

Editable vector text, blend modes, masks, PSD support, transform handles, advanced selection tools, non-destructive filters, and GPU acceleration remain out of scope for this version.