# PocketGB

![PocketGB logo](assets/PocketGB-logo.svg)

PocketGB is a lightweight desktop emulator for original Nintendo Game Boy and Game Boy Color cartridges. It includes save states, automatic cartridge saves, keyboard/gamepad input, configurable display filters, window/fullscreen controls, and a self-contained runtime.

## Latest Windows build

The current release is available from the official [PocketGB GitHub Releases page](https://github.com/siddop422/Pixel-Lab/releases).

| Download | What it is |
| --- | --- |
| **PocketGB-Setup-1.2.0.exe** | Windows 10/11 x64 installer. Installs per-user, adds Start Menu shortcuts, and can optionally add a desktop shortcut or associate .gb/.gbc files. |
| **PocketGB-Portable-1.2.0.zip** | Self-contained Windows x64 portable build. Extract and run `PocketGB.exe`. |
| **SHA256SUMS.txt** | SHA-256 hashes for verifying the exact downloaded files. |

The installer keeps the same application ID and install directory between versions, so running a newer setup over PocketGB 1.1.0 upgrades that installation instead of creating a second app entry. User configuration and game saves are stored separately from the application directory.

**Safe download guidance:** download only from the official GitHub Releases page linked above. Compare the installer/ZIP hash with `SHA256SUMS.txt` before running it. The Windows installer is not Authenticode-signed, so Windows SmartScreen may show an unknown-publisher warning; a checksum confirms file integrity, not publisher identity.

## What's new in 1.2.0

- PocketGB application, taskbar, and installer icon branding.
- Larger, scrollable display settings with custom window width/height, fullscreen, and V-Sync.
- Nearest-neighbour, bilinear, and sharp-bilinear GPU texture filtering.
- LCD grid, scanlines, CRT curvature/vignette, brightness, and saturation.
- Experimental temporal frame blending. This blends adjacent frames and can cause ghosting; it does **not** use motion vectors, interpolate object movement, or double the real game FPS.
- Live OpenGL vendor, renderer, and driver/version diagnostics.
- A low-end graphics profile that disables optional post-processing and frame blending.
- Correct ROM header handling for special Game Boy ROM size codes 0x52, 0x53, and 0x54.
- Standard ROM+RAM and ROM+RAM+battery cartridge handling.
- Unsupported cartridge mapper IDs now produce an explicit error instead of being silently treated as ROM-only.

## Systems and cartridge compatibility

| System / cartridge | Status |
| --- | --- |
| Original Game Boy (DMG) | Supported by the current core |
| Game Boy Color (CGB) | Supported by the current core |
| Standard ROM-only, MBC1, MBC2, MBC3, and MBC5 types | Implemented |
| ROM+RAM and ROM+RAM+battery (0x08/0x09) | Implemented in this update |
| Special ROM size codes 0x52/0x53/0x54 | Header parsing implemented |
| MBC6, MBC7, MMM01, HuC-1, HuC-3, TAMA5, Pocket Camera | Not implemented yet; the emulator now reports unsupported mapper IDs clearly |
| Super Game Boy enhancements | Not implemented |
| Game Boy Advance (.gba) | **Not supported** |

PocketGB is a Game Boy / Game Boy Color emulator, not a universal handheld emulator. GBA uses different hardware and requires a separate GBA emulation core. A `.gba` file cannot be made compatible by changing its extension or adding it to the file picker. No commercial ROMs or BIOS files are included.

“Supported” means the core has an implementation for the listed system/controller; it is not a claim that every commercial or homebrew ROM has been individually tested. The repository's automated tests cover core components and cartridge parsing, but do not establish a 100% compatibility rate. Please report a reproducible issue with the ROM title and mapper information when a game fails.

## Display and graphics

- Window resolution presets and custom window width/height.
- Fullscreen and V-Sync.
- Integer scaling and 10:9 aspect-ratio lock.
- Nearest-neighbour (pixel-perfect), bilinear, and sharp-bilinear texture filters.
- DMG green, grey, Pocket, and yellow palettes.
- Optional scanlines, LCD pixel grid, and CRT curvature/vignette.
- Brightness and saturation adjustment.
- Experimental temporal frame blending.
- A low-end profile for weaker CPUs/GPUs.

**Resolution note:** these settings change the desktop window/output size. The emulated Game Boy framebuffer remains 160×144 pixels; a larger output resolution does not increase the original console's internal resolution or create new game detail.

**Graphics backends:** OpenGL 3.3 Core is the only implemented graphics API in this build. The Video tab reports the active GPU vendor, renderer, and driver/version. Vulkan and Direct3D are not exposed as selectable options because working renderers for those APIs have not been implemented.

**Audio backends:** Settings includes Auto, SDL, and OpenAL. A backend change applies after restarting PocketGB.

## Controls

| Game Boy button / action | Default keyboard key |
| --- | --- |
| D-pad | Arrow keys |
| A | Z |
| B | X |
| Start | Enter |
| Select | Right Shift |
| Pause / resume | Space |
| Quick save | F5 |
| Quick load | F8 |
| Choose save slot | 0–9 |
| Fast-forward (hold) | Tab |
| Frame advance while paused | N |
| Show / hide debug tools | F11 |
| Reset | R |

Keyboard and gamepad bindings can be changed in Settings.

## Saves and supported files

- Ten save-state slots per game, with thumbnails and timestamps.
- Quick save (F5) and quick load (F8).
- Automatic battery-backed cartridge saves (.sav), including MBC3 RTC data.
- Save files and states are stored next to the original ROM, or in the optional save folder.
- Direct .gb, .gbc, and .sgb cartridge images, plus ZIP archives containing those files.
- ZIP extraction is cached; replacing an archive invalidates the old cache. Save files remain beside the original ZIP, not in the cache.
- ZIP entries are limited to 64 MiB. 7z and RAR archives are not supported.

## Performance and requirements

- Windows 10/11 x64 with an OpenGL 3.3-compatible graphics driver.
- The application bundles its .NET runtime and native application dependencies; a separate .NET install is not required.
- A recent Intel, AMD, or NVIDIA graphics driver is recommended.
- On low-end hardware, use the Low-end / maximum performance preset, pixel-perfect scaling, and keep CRT/LCD effects and temporal blending disabled.

The core renders at the Game Boy's native frame rate. The FPS counter measures application presentation/rendering and can vary with window composition, GPU drivers, V-Sync, and system load.

## Build from source

This branch uses the MIT-licensed [GameboySharp emulator core](https://github.com/sokie/gameboy_sharp), pinned as a Git submodule.

```powershell
git clone --recurse-submodules --branch pocketgb-display-settings https://github.com/siddop422/Pixel-Lab.git PocketGB
cd PocketGB
pwsh ./scripts/Prepare.ps1
dotnet test ./vendor/GameboySharp/GameboySharp.sln -c Release
dotnet publish ./vendor/GameboySharp/GameboySharp.csproj -c Release -r win-x64 --self-contained true -p:AssemblyName=PocketGB -p:Version=1.2.0 -o publish
```

To build the Windows installer, install Inno Setup 6 and run:

```powershell
& "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" /DAppVersion="1.2.0" /DPublishDir="..\publish" .\install\PocketGB.iss
```

## Credits and license

The emulation engine is based on [sokie/gameboy_sharp](https://github.com/sokie/gameboy_sharp), licensed under the MIT License. Its copyright and license notice are preserved in `vendor/GameboySharp/LICENSE` and `THIRD-PARTY-NOTICES.md`.

PocketGB is an independent community project and is not affiliated with or endorsed by Nintendo.
