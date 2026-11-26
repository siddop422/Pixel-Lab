# PocketGB 1.6.0

**Release type:** Windows x64 desktop + universal Android APK.

## Downloads

- `PocketGB-Setup-1.6.0.exe` — self-contained Windows 10/11 x64 installer.
- `PocketGB-Portable-1.6.0.zip` — self-contained Windows x64 portable build.
- `PocketGB-Android-1.6.0.apk` — one Android APK with native mGBA libraries for ARM64, ARMv7, x86_64 and x86.
- `SHA256SUMS.txt` and `SHA256-ANDROID.txt` — SHA-256 checksums for Windows packages and Android APK.

## Compatibility improvements

- One shared cartridge resolver is used by Windows desktop, Windows portable and Android.
- Raw GB, GBC, SGB-tagged GB and GBA images are detected by the actual cartridge header, rather than trusting the filename.
- Common raw-image aliases `.gbx`, `.agb`, `.dmg`, `.cgb`, `.bin`, `.rom` and `.pak` are accepted only when mGBA recognises the underlying cartridge.
- ZIP archives are extracted deterministically using a content-addressed cache. The loader validates archive contents and enforces size limits.
- ZIP and 7z containers renamed to `.pak` are identified by their file signatures. Other PAK files are treated as raw-ROM candidates; arbitrary proprietary game-engine PAK formats are not supported.
- Native mGBA 7z support scans nested folders and retains the archive handles for as long as the loaded cartridge needs them.
- Windows desktop can automatically apply adjacent IPS, UPS and BPS patches. Android provides a PATCH toolbar action for manual patch selection.
- Unreadable battery saves are preserved as `.corrupt-*` backups rather than preventing a valid game from opening.
- ZIP-launched games keep save files beside the original archive, not in the temporary ROM cache.

## Android

- One APK includes `arm64-v8a`, `armeabi-v7a`, `x86_64` and `x86` native libraries.
- Minimum supported OS: Android 6.0 / API 23.
- Includes touch controls, hardware-key input, file picker, audio, pause/reset, speed/turbo, quick saves and battery saves.
- No game ROMs or copyrighted BIOS images are bundled.

## Compatibility boundaries

- `.sgb` files run as standard Game Boy cartridges. Full Super Game Boy border, palette and accessory enhancement rendering is not implemented.
- RAR archives and arbitrary proprietary PAK formats are not supported.
- This improves broad cartridge compatibility but cannot guarantee every commercial game, mapper, special peripheral or ROM hack.
- Balatro GBA and Geometry Dash GB/GBC ROM images are not bundled or used in automated tests. The project uses synthetic test cartridges and archive fixtures instead.

## Release validation gate

Before publication, CI must pass:
- Native mGBA build and Windows emulator tests, including synthetic GB, GBC, SGB-flagged GB and GBA boot/frame/save-state checks.
- Shared ROM/archive resolver tests, including PAK signature detection, ZIP extraction, corrupt/oversized inputs and sidecar patch discovery.
- Self-contained Windows x64 publish, Inno Setup installer compilation and portable ZIP creation.
- Native mGBA builds for all four Android ABIs.
- Android APK publish, signature verification, and checks that all four `lib/<abi>/libpocketgb-mgba.so` libraries are present.

CI package checks are not a substitute for gameplay testing on physical devices. The Windows installer is not Authenticode-signed; verify published downloads with the provided SHA-256 checksums.
