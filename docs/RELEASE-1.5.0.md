# PocketGB 1.5.0

**Release type:** Windows x64 desktop + multi-ABI Android APK.

## Downloads

- `PocketGB-Setup-1.5.0.exe` — self-contained Windows 10/11 x64 installer.
- `PocketGB-Portable-1.5.0.zip` — self-contained Windows x64 portable build.
- `PocketGB-Android-1.5.0.apk` — one Android APK with native mGBA libraries for ARM64, ARMv7, x86_64 and x86.
- `SHA256SUMS.txt` and `SHA256-ANDROID.txt` — SHA-256 hashes for the Windows packages and Android APK.

## Android changes

- Expand Android ABI coverage from arm64-v8a only to arm64-v8a, armeabi-v7a, x86_64 and x86 in one APK.
- Compile the same pinned mGBA GB/GBA core separately with the Android NDK for each ABI.
- Keep the minimum Android version at Android 6.0 (API 23).
- Keep touchscreen D-pad and buttons, hardware-key input, file picker, stereo audio, pause/reset, speed/turbo, battery saves and quick save/load.
- Bound imported ROMs to 32 MiB and ZIP uploads to 64 MiB before copying them into private app storage.
- Use a SHA-256-derived private filename so distinct games with the same source filename do not overwrite each other's saves.
- Validate ZIP extraction lengths and bound save-state / battery-save file reads.

The APK is larger than the previous arm64-only APK because it includes four native architectures. Each device installs and loads the native library matching its ABI.

## Compatibility notes

- GB, GBC and GBA cartridges use the pinned native mGBA core.
- `.sgb` files can run as standard GB cartridges. SGB border, palette and accessory enhancements are not implemented.
- 7z/RAR archives are not supported.
- No commercial ROMs or BIOS dumps are bundled.
- Android device compatibility is improved at the ABI level; this does not guarantee every ROM, mapper, peripheral or ROM hack works.
- Commercial ROM images are not bundled into the repository or CI. The Balatro GBA and Geometry Dash GB/GBC images are not part of automated tests.

## Validation gate

The release workflow must pass:
- Windows emulator test suite.
- Self-contained Windows x64 publish.
- Inno Setup installer compilation.
- Windows portable ZIP and SHA-256 generation.
- Native mGBA compilation for all four Android ABIs.
- Android .NET publish.
- APK signature verification.
- APK content check for `lib/arm64-v8a/libpocketgb-mgba.so`, `lib/armeabi-v7a/libpocketgb-mgba.so`, `lib/x86_64/libpocketgb-mgba.so` and `lib/x86/libpocketgb-mgba.so`.

CI package validation is not a substitute for gameplay testing on physical devices. The release remains unsigned by Authenticode on Windows; verify published downloads using the provided checksums.

## CI validation — completed before publication

Pull request [#6](https://github.com/siddop422/Pixel-Lab/pull/6) was merged after both CI jobs passed.

- Windows test suite: **93 passed, 0 failed, 7 skipped (100 total)**. The seven skipped tests depend on optional external ROM or CPU-vector datasets not bundled with the repository.
- Windows x64: native mGBA build, self-contained publish, Inno Setup compile, portable ZIP creation and artifact upload passed.
- Android: mGBA native libraries compiled for `arm64-v8a`, `armeabi-v7a`, `x86_64` and `x86`.
- Android: .NET APK publish, `apksigner` verification and ZIP-content checks for all four `lib/<abi>/libpocketgb-mgba.so` paths passed.
- CI produced a signed universal APK of approximately 16 MiB. CI package validation is not a physical-device gameplay test.
- The seven skipped tests, SGB enhancement rendering and testing the named commercial ROM examples remain outside this CI run.

Workflow runs:
- [Windows build and test](https://github.com/siddop422/Pixel-Lab/actions/runs/45877689931)
- [Android universal APK](https://github.com/siddop422/Pixel-Lab/actions/runs/45877690075)

