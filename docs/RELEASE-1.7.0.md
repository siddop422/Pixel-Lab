# PocketGB 1.7.0

**Status:** Released November 28, 2026. Windows and Android CI passed.

## Downloads

- `PocketGB-Setup-1.7.0.exe` — Windows 10/11 x64 per-user installer.
- `PocketGB-Portable-1.7.0.7z` — LZMA2 maximum-compression portable folder.
- `PocketGB-Portable-1.7.0.zip` — portable folder in ZIP format.
- `PocketGB-Android-1.7.0.apk` — universal APK for ARM64, ARMv7, x86_64 and x86.
- SHA-256 checksum files for the Windows packages and Android APK.

The portable archives contain one `PocketGB` folder. Open that folder and run `PocketGB.exe`; keep the native mGBA DLL and other runtime files beside it. `START-HERE.txt` is included inside the folder.

## Stability changes

- Failed native mGBA initialisation is cleaned up without calling the core deinitializer on a core that never completed initialisation.
- The desktop mGBA host catches recoverable errors returned through the native adapter, pauses the affected game and keeps the UI alive.
- The original Game Boy core loop also catches managed frame/audio exceptions, pauses the game and continues to display PocketGB.
- The error panel has a **Copy error report** action that includes the managed stack trace and any recorded native crash details.
- Recent reports from a previous run are shown on the next launch, so a native runtime failure can still be copied after restarting.
- Native Windows faults are recorded to `%LOCALAPPDATA%\PocketGB\logs\native-crash.txt`.
- Managed errors and application logs are stored in `%LOCALAPPDATA%\PocketGB\logs`.

A fatal memory-corruption exception in native code cannot safely be resumed in the same process. PocketGB records the failure and offers its report on the next launch; the native initialisation cleanup change is intended to prevent one known invalid-teardown path.

## Size and packaging

- Windows publish uses a self-contained single-file app host with compressed managed assemblies.
- Native libraries remain as side-by-side files where required by the runtime; the portable folder keeps all of them together with `PocketGB.exe`.
- Optional mGBA image, database, scripting, video-recording and external archive integrations are disabled in the native engine build. The bundled 7z reader remains enabled.
- The 7z portable package uses LZMA2 maximum compression; ZIP is also provided for compatibility.

The installer keeps the existing application ID and installation directory so v1.7.0 upgrades an existing PocketGB installation.

## Validation results

The release checks completed successfully:

- Native mGBA core build and native GB/GBC/GBA load, frame, save-state and repeated GB/GBA reload tests.
- Shared ZIP/PAK/7z loader tests and corrupt/oversized input checks.
- Windows self-contained single-file publish, installer compilation, portable folder staging and both ZIP/7z archives.
- Android mGBA builds for all four ABIs, APK publishing and signature verification.
- A check that every expected native library is present in the final Android APK.

These automated tests do not replace testing on real games and physical devices. No commercial ROMs or BIOS files are included. The Windows installer is not Authenticode-signed; use the published SHA-256 checksums to verify download integrity.
