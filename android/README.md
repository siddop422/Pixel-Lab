# PocketGB for Android

PocketGB Android is a native Android front end using the same pinned mGBA core as the Windows build. It has a landscape game view, touch controls, hardware-key support, Android's document picker and native stereo audio output.

## Supported cartridges and files

- Game Boy: `.gb`
- Game Boy Color: `.gbc`
- Super Game Boy ROM files: `.sgb` (the game runs through the standard GB core; SGB border, palette and other SGB enhancement features are not implemented)
- Game Boy Advance: `.gba`
- ZIP archives containing at least one supported ROM

ZIP entries are selected deterministically by folder depth and filename. The extracted ROM must be 32 MiB or smaller; imported ZIP files are limited to 64 MiB. 7z and RAR are not supported. No commercial ROMs or BIOS dumps are included; mGBA's HLE BIOS defaults are used.

## Android support

- Android 6.0 (API 23) or newer.
- One APK containing native libraries for all four Android ABIs:
  - `arm64-v8a` — 64-bit ARM phones and tablets.
  - `armeabi-v7a` — 32-bit ARM phones and tablets.
  - `x86_64` — 64-bit x86 Android emulators and devices.
  - `x86` — 32-bit x86 Android emulators and devices.
- Full-screen landscape play, touch D-pad, A/B, L/R, Start and Select buttons.
- External keyboards and game controllers where Android reports standard key events.
- Stereo AudioTrack output, pause, reset, speed, turbo, quick save and quick load.
- Game ROMs are copied to app-private storage using content-addressed filenames so two different games with the same source filename do not overwrite each other's saves.
- Battery saves (`.sav`) and quick states (`.state0`) are stored beside the app-private ROM copy.

The APK uses the .NET 10 Android runtime and native mGBA libraries built from the same pinned upstream revision as the Windows app. Including multiple ABIs increases the APK size compared with the previous arm64-only build, but avoids requiring users to guess which architecture-specific APK to download.

## Build

The Android project is a standalone .NET 10 Android app; it does not reuse the Windows Silk.NET desktop windows. The emulator engine is the same mGBA revision used by PocketGB Windows.

~~~bash
dotnet workload install android
sdkmanager "platforms;android-36" "build-tools;36.0.0" "ndk;27.2.12479018" "cmake;3.22.1"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/27.2.12479018"
./scripts/build-mgba-android.sh
dotnet publish ./android/PocketGB.Android.csproj -c Release -f net10.0-android -p:AndroidPackageFormat=apk -o ./publish/android
~~~

The build script compiles the core for each ABI declared in `RuntimeIdentifiers`; the project packages them into a single APK. CI checks that each expected `lib/<abi>/libpocketgb-mgba.so` exists in the signed APK and verifies the APK signature.

The native core is pinned to mGBA commit [431935616c0e216d650b25b2ea0c0acccd359038](https://github.com/mgba-emu/mgba/commit/431935616c0e216d650b25b2ea0c0acccd359038) and is licensed under MPL-2.0. The native licence file is packaged in the APK assets.

## Installing the APK

Download `PocketGB-Android-1.6.0.apk` from the [PocketGB v1.6.0 release](https://github.com/siddop422/Pixel-Lab/releases/tag/pocketgb-v1.5.0), enable Android's Install unknown apps permission for the browser/file manager used to open it, then install it. Open PocketGB and press OPEN to choose a ROM from Downloads or another document provider.

## Signing and updates

The APK is signed so Android can install it. For repeatable upgrade installs, configure a persistent signing key in repository Actions secrets: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD`. If those secrets are absent, CI creates a one-off signing key; a later APK signed with a different key cannot update it in place. Back up saves before uninstalling an app signed with the one-off key.

## Compatibility and validation

Windows CI exercises synthetic GB, GBC, SGB-flagged GB and GBA cartridge boot, frame execution, framebuffer dimensions and save-state round-trips, including GBA detection with a `.pak` filename. A second suite tests shared raw/ZIP/PAK/7z path handling, archive size limits, corrupt archives and sidecar patch discovery. Android CI builds the mGBA native library for all four ABIs, checks that all four libraries are packaged into the APK, and verifies its signature. These checks do not replace testing on physical phones or Android emulator images, and do not guarantee every commercial ROM, mapper, accessory or ROM hack works.

The exact Balatro GBA and Geometry Dash GB/GBC images have not been included in automated tests. Standard `.sgb` cartridge execution is supported, but SGB-specific enhancement rendering is not implemented. RAR, proprietary PAK containers, special cartridge peripherals and unsupported mappers remain outside the compatibility promise. Report the ROM title, platform, Android ABI/device/API level and any reproducible error for compatibility fixes.
