# PocketGB 1.4.0

**Release type:** Windows desktop + Android arm64.

## Windows downloads

- `PocketGB-Setup-1.4.0.exe` — self-contained Windows 10/11 x64 installer.
- `PocketGB-Portable-1.4.0.zip` — self-contained portable Windows x64 build.
- `SHA256SUMS.txt` — SHA-256 hashes for the Windows downloads.

## Android download

- `PocketGB-Android-arm64-1.4.0.apk` — signed native Android APK for Android 6.0+ on 64-bit ARM phones/tablets.
- `SHA256-ANDROID.txt` — SHA-256 hash for the APK.

The Android APK uses the pinned native mGBA engine and supports GB, GBC and GBA cartridges, with touchscreen controls, Android document picker, audio, save states, battery saves and speed controls. ZIP archives containing a supported ROM can also be opened. It does not include games or commercial BIOS images.

The first APK targets `arm64-v8a` only; x86_64 emulators and 32-bit-only phones are not covered. The CI build is signed with a persistent key only when repository signing secrets are configured. Otherwise it uses a one-off signing key, so future differently-signed updates require uninstall/reinstall; back up saves first.

## Emulation and performance

- Native mGBA core for GBA and GB/GBC.
- Auto selects the most broadly compatible mGBA core for GB, GBC and GBA ROMs.
- GameboySharp remains available as a manual GB/GBC fallback in the Windows desktop build.
- Real frame-based speed multiplier and configurable turbo; render FPS and emulated game FPS are reported separately.
- OpenGL 3.3 remains the only implemented graphics API. Vulkan and GPU-independent software window presentation are not yet available.

## Validation

The release is gated on Windows tests, self-contained publishing, installer/portable packaging, Android mGBA native compilation, Android APK publishing, APK signature verification and artifact uploads.

Automated synthetic GB/GBA smoke tests validate cartridge detection, frame execution, framebuffer dimensions and state serialization. They do not constitute real-device gameplay tests for every commercial ROM or homebrew. Balatro GBA and Geometry Dash GB/GBC have not been individually tested on a physical Android device.

No commercial ROMs or BIOS images are bundled. The mGBA core is pinned to `431935616c0e216d650b25b2ea0c0acccd359038`; the MPL-2.0 license notice is included in the Android APK and Windows native package.
