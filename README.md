# PocketGB

![PocketGB logo](assets/PocketGB-logo.svg)

PocketGB is a lightweight Windows desktop and Android emulator for Nintendo Game Boy, Game Boy Color, and Game Boy Advance cartridges. It uses the native mGBA core for broad cartridge compatibility, with save states, battery saves, keyboard/gamepad/touch input, configurable display filters, speed controls, and self-contained releases.

## Next build: v1.7.0 (CI validation pending)\n\nThe next build is being prepared with a compressed single-file Windows executable, a `PocketGB` portable folder, ZIP and maximum-compression LZMA2/7z archives, safer native mGBA initialisation cleanup, recoverable frame errors, and copyable diagnostics. See [the v1.7.0 release notes](docs/RELEASE-1.7.0.md). This is a preview of work in progress; **v1.6.0 remains the latest published release until v1.7.0 passes CI and is attached to GitHub Releases.**\n\nWhen v1.7.0 is ready, native crash reports will be written to `%LOCALAPPDATA%\\PocketGB\\logs\\native-crash.txt`; managed error reports and application logs go in the same `logs` folder.\n\n## Latest Windows build

The current release is **PocketGB 1.6.0**. Download the [Windows installer](https://github.com/siddop422/Pixel-Lab/releases/download/pocketgb-v1.6.0/PocketGB-Setup-1.6.0.exe), [portable ZIP](https://github.com/siddop422/Pixel-Lab/releases/download/pocketgb-v1.6.0/PocketGB-Portable-1.6.0.zip), or [Android APK](https://github.com/siddop422/Pixel-Lab/releases/download/pocketgb-v1.6.0/PocketGB-Android-1.6.0.apk). Verify Windows downloads with [SHA256SUMS.txt](https://github.com/siddop422/Pixel-Lab/releases/download/pocketgb-v1.6.0/SHA256SUMS.txt) and the APK with [SHA256-ANDROID.txt](https://github.com/siddop422/Pixel-Lab/releases/download/pocketgb-v1.6.0/SHA256-ANDROID.txt). See [all PocketGB releases](https://github.com/siddop422/Pixel-Lab/releases).

| Download | What it is |
| --- | --- |
| **PocketGB-Setup-1.6.0.exe** | Windows 10/11 x64 installer. Installs per-user and upgrades the existing PocketGB installation. |
| **PocketGB-Portable-1.6.0.zip** | Self-contained Windows x64 portable build. Extract and run `PocketGB.exe`. |
| **SHA256SUMS.txt / SHA256-ANDROID.txt** | SHA-256 hashes for Windows and Android downloads. |

The installer retains the same application ID and install folder, so running a newer setup over PocketGB 1.2.0 upgrades that installation instead of creating a second app entry. User configuration and game saves remain separate from the application directory.

**Safe download guidance:** download only from the official GitHub Releases page. Compare the installer/ZIP hash with `SHA256SUMS.txt` before running it. The installer is not Authenticode-signed; SmartScreen may show an unknown-publisher warning. A checksum confirms file integrity, not publisher identity.

## Android APK

PocketGB 1.6.0 also includes a native Android app for Android 6.0+ on ARM64, ARMv7, x86_64 and x86 devices. Download the [PocketGB Android APK](https://github.com/siddop422/Pixel-Lab/releases/download/pocketgb-v1.6.0/PocketGB-Android-1.6.0.apk) from the same release page.

The Android build uses the pinned native mGBA core for GB, GBC and GBA games, with a landscape display, touch D-pad/buttons, hardware-key input, Android file picker, stereo audio, pause/reset, speed/turbo, save states and battery saves. It accepts raw cartridge files, ZIP and 7z archives, and `.pak` files when they contain either a ZIP container or a real GB/GBC/GBA ROM image. The universal APK bundles mGBA native libraries for `arm64-v8a`, `armeabi-v7a`, `x86_64` and `x86`.

Read the [Android install/build guide](android/README.md). The APK is signed for installation. For seamless updates across releases, configure a persistent signing key in GitHub Actions secrets; if CI uses its one-off fallback key, uninstall the older APK and back up its saves before installing a differently-signed future build.

## What's new in 1.6.0

- Unified ROM loading across the Windows desktop app, portable ZIP and Android APK.
- Native mGBA 7z support, including nested folders, plus ZIP and ZIP-based PAK detection.
- Automatic desktop IPS/UPS/BPS sidecar patch loading; Android has an explicit PATCH action for IPS/UPS/BPS.
- Broader raw cartridge filename aliases including .gbx, .agb, .dmg, .cgb, .bin, .rom and .pak; mGBA validates the actual ROM header.
- Automated coverage for GB, GBC, SGB-flagged GB, GBA, ZIP imports, PAK aliases, corrupt/oversized inputs and save-state round-trips.
- Damaged battery saves are preserved as .corrupt-* backups instead of preventing an otherwise valid game from opening.
- Universal Android APK retains all four ABIs: ARM64, ARMv7, x86_64 and x86.
## Systems and cartridge compatibility

| System / cartridge | Status |
| --- | --- |
| Original Game Boy (DMG) | mGBA in Auto mode; GameboySharp manual fallback |
| Game Boy Color (CGB) | mGBA in Auto mode; GameboySharp manual fallback |
| Game Boy Advance (GBA) | mGBA native core on Windows x64 and all four Android ABIs |
| Standard ROM-only, MBC1, MBC2, MBC3, and MBC5 | Implemented by GameboySharp |
| Standard ROM+RAM and ROM+RAM+battery (0x08/0x09) | Implemented by GameboySharp |
| Special GB ROM size codes 0x52/0x53/0x54 | Header parsing implemented |
| MBC6, MBC7, MMM01, HuC-1, HuC-3, TAMA5, Pocket Camera | Not implemented in GameboySharp; uncommon cartridge types are reported clearly |
| Super Game Boy enhancements | `.sgb` cartridges run as GB games; full SGB border/controller enhancement rendering is not implemented |

mGBA is the recommended Auto core for GBA and GB/GBC because it supports a broader set of cartridge types; GameboySharp remains available as a manual GB/GBC fallback on Windows. mGBA detects cartridge platform from ROM bytes rather than trusting the filename. No emulator can guarantee every game, mapper, special peripheral, or ROM hack works perfectly. CI now runs generated native GB, GBC, SGB-flagged GB and GBA boot/frame/save-state tests, plus ZIP loader and corrupt-input tests; named commercial/homebrew examples still require separate real-game testing.

No commercial ROMs or BIOS files are included. mGBA's HLE BIOS is used by default.

## Emulation backends

Open **Settings → General → Emulation core**:

| Option | Behaviour |
| --- | --- |
| **Auto (recommended)** | Prefers mGBA for `.gba`, `.gb`, `.gbc`, and `.sgb` for broader cartridge compatibility |
| **GameboySharp (GB/GBC)** | Uses the original Game Boy / Color core |
| **mGBA (GB/GBC/GBA)** | Uses the native mGBA core for supported GBA and GB/GBC images |

The mGBA core is a separate native library built from pinned upstream mGBA source. Auto uses it for all supported handheld ROM types; choose GameboySharp manually when you need the original GB/GBC core and its debugger/save-state features. mGBA is not a GameboySharp extension or a file-extension trick.

## Display and graphics

- Window resolution presets and custom window width/height.
- Fullscreen and V-Sync.
- Integer scaling and aspect-ratio preservation.
- Nearest-neighbour, bilinear, and sharp-bilinear filtering in the GameboySharp display.
- DMG green, grey, Pocket, and yellow palettes.
- Optional scanlines, LCD pixel grid, CRT curvature/vignette, brightness, and saturation.
- A low-end profile for weaker CPUs/GPUs.

**Graphics API:** OpenGL 3.3 Core is the only implemented graphics API. The mGBA window uses the same OpenGL presentation path. Vulkan and Direct3D are not exposed as working choices because their renderers have not been implemented. CPU-only window presentation is not implemented.

**Resolution note:** enlarging the desktop window only scales the console's original framebuffer. It does not create extra source detail.

## Speed and performance

Normal speed (0.5× / 1× / 2×) changes actual emulated frame advancement, not just the time the UI loop sleeps. Hold **Tab** for configurable turbo (2×–16×) in Settings → General. The top-right overlay reports **RENDER FPS**, **GAME FPS**, and measured emulation speed separately. Turbo reduces UI/GL redraw frequency so more time is available to the emulation core.

On lower-end hardware, use the Low-end / maximum performance profile, pixel-perfect scaling, and keep optional post-processing disabled. Performance depends on the game, audio output, driver and system load.

## Controls

| Game Boy / GBA action | Default keyboard key |
| --- | --- |
| D-pad | Arrow keys |
| A / B | Z / X |
| Start / Select | Enter / Right Shift |
| GBA L / R | A / S |
| Pause / resume | Space |
| Fast-forward (hold) | Tab |
| Quick save / load | F5 / F8 |
| Reset in mGBA window | F9 |
| Frame advance while paused (GameboySharp) | N |
| Show / hide GameboySharp debug tools | F11 |

Gamepad D-pad, face buttons, Start/Back and shoulder/trigger buttons are mapped where supported by the connected controller. Game Boy bindings can be changed in Settings.

## Saves and supported files

- Direct .gb, .gbc, .sgb, .gba and raw-image aliases .gbx, .agb, .dmg, .cgb, .bin, .rom and .pak. An alias is accepted only when mGBA recognises the actual cartridge header.
- ZIP and 7z archives containing supported GB/GBC/GBA cartridges. ZIP entries are selected in deterministic folder-depth and filename order; nested 7z folders are scanned in the archive's directory order.
- ZIP or 7z containers renamed .pak are identified by their file signatures. Other .pak files are treated as raw ROM candidates, not as a promise to support every proprietary game-engine PAK archive.
- IPS/UPS/BPS patches: Windows desktop applies matching sidecar patches automatically (BPS, then UPS, then IPS); Android provides a PATCH button for manual patch selection.
- GameboySharp: ten save-state slots, quick save/load and battery-backed .sav files, including MBC3 RTC data.
- mGBA: quick save/load state (.state0) and battery-backed .sav data.
- Saves for ZIP-launched games remain beside the original archive rather than inside the extracted ROM cache.
- Raw ROMs and extracted archive entries are limited to 32 MiB; ZIP, 7z and ZIP-based PAK containers are limited to 128 MiB. RAR is not supported.
- Unreadable battery saves are preserved as timestamped .corrupt-* backups so they do not block game startup.
## Requirements

- Windows 10/11 x64 for the desktop app.
- Android 6.0+ (API 23+) on ARM64 (`arm64-v8a`), 32-bit ARM (`armeabi-v7a`), x86_64 or x86 for the universal APK.
- OpenGL 3.3-compatible graphics driver.
- The application bundles its .NET runtime and native mGBA core; a separate .NET install is not required.
- Recent Intel, AMD, or NVIDIA graphics drivers are recommended.
- No external BIOS file is required for the default mGBA HLE BIOS setup.

## Build from source

The GameboySharp core is pinned as a Git submodule. mGBA is pinned separately and built as a minimal core-only native library.

```powershell
git clone --recurse-submodules https://github.com/siddop422/Pixel-Lab.git PocketGB
cd PocketGB
git clone https://github.com/mgba-emu/mgba.git third_party/mgba
git -C third_party/mgba checkout 431935616c0e216d650b25b2ea0c0acccd359038
pwsh ./scripts/Prepare.ps1
pwsh ./scripts/Build-Mgba.ps1
dotnet test ./vendor/GameboySharp/GameboySharp.sln -c Release
dotnet publish ./vendor/GameboySharp/GameboySharp.csproj -c Release -r win-x64 --self-contained true -p:AssemblyName=PocketGB -p:Version=1.6.0 -o publish
```

The native mGBA core is MPL-2.0 licensed; its notice is included with the Windows output. No game ROMs or BIOS dumps are included.

## Further technical notes

- [GBA backend and compatibility](docs/GBA-BACKEND-AND-COMPATIBILITY.md)
- [Stability and renderer backend roadmap](docs/STABILITY-AND-RENDER-BACKENDS.md)

## Credits and license

The GameboySharp emulation core is MIT-licensed; its license is preserved in `vendor/GameboySharp/LICENSE` and `THIRD-PARTY-NOTICES.md`. The mGBA native core is MPL-2.0-licensed and its notice is included in the Windows build output.

PocketGB is an independent community project and is not affiliated with or endorsed by Nintendo.
