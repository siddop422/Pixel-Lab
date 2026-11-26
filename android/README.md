# PocketGB for Android

PocketGB Android is a native Android front end using the same pinned mGBA core as the Windows build. The UI is Android-native, with a landscape game view, touch controls, hardware-key support and Android's document picker.

## Supported cartridges and files

- Game Boy: .gb
- Game Boy Color: .gbc
- Super Game Boy ROM files: .sgb (standard GB core; SGB enhancements are not implemented in this Android front end)
- Game Boy Advance: .gba
- ZIP archives containing one supported ROM

ZIP extraction selects a supported ROM in stable order and rejects entries over the native core's 32 MiB ROM limit. 7z and RAR are not supported. No commercial ROMs or BIOS dumps are included; mGBA's HLE BIOS defaults are used.

## Android support

- Android 6.0 (API 23) or newer.
- arm64-v8a phones and tablets (64-bit ARM).
- Full-screen landscape play, touch D-pad, A/B, L/R, Start and Select buttons.
- External keyboards and game controllers where Android reports standard key events.
- Stereo AudioTrack output, pause, reset, speed, turbo, quick save and quick load.
- Cartridge .sav and quick state .state0 files are stored in the app's private files directory.

The first APK targets modern 64-bit ARM devices to keep its size down. x86_64 Android emulators and 32-bit-only devices are not included in this APK.

## Build

The Android project is a standalone .NET 9 Android app; it does not reuse the Windows Silk.NET desktop windows. The emulator engine is the same mGBA revision used by PocketGB Windows.

~~~bash
dotnet workload install android
sdkmanager "platforms;android-36" "build-tools;36.0.0" "ndk;27.2.12479018" "cmake;3.22.1"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/27.2.12479018"
./scripts/build-mgba-android.sh
dotnet publish ./android/PocketGB.Android.csproj -c Release -f net10.0-android -r android-arm64 -p:AndroidPackageFormat=apk -o ./publish/android
~~~

The native core is pinned to mGBA commit 431935616c0e216d650b25b2ea0c0acccd359038 and is licensed under MPL-2.0. The native licence file is also packaged in the APK assets.

## Installing the APK

Download PocketGB-Android-arm64-1.4.0.apk from the [PocketGB v1.4.0 release](https://github.com/siddop422/Pixel-Lab/releases/tag/pocketgb-v1.4.0), enable Android's Install unknown apps permission for the browser/file manager used to open it, then install it. Open PocketGB and press OPEN to choose a ROM from Downloads or another document provider.

The APK is signed so Android can install it. For repeatable upgrade installs, configure a persistent signing key in repository Actions secrets: ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, and ANDROID_KEY_PASSWORD. If those secrets are absent, CI creates a one-off signing key; uninstall that one-off build before installing a later APK signed by a different key. Back up saves before uninstalling.

## Compatibility status

Windows CI exercises synthetic GB and GBA cartridge boot, frame execution, native framebuffer dimensions and save-state round-trips. These tests do not guarantee every commercial ROM or special peripheral works. The exact Balatro GBA and Geometry Dash GB/GBC images have not been included in automated tests. Report the ROM title, platform, Android version and any reproducible error for compatibility fixes.
