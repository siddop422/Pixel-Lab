# PocketGB

PocketGB is a lightweight desktop emulator for original Game Boy and Game Boy Color games. It includes a clean dark-green interface, save states, automatic cartridge saves, keyboard/gamepad input, and a self-contained runtime.

## Download

Open [PocketGB Releases](https://github.com/siddop422/Pixel-Lab/releases) and choose the build for your computer:

| Platform | Download |
| --- | --- |
| Windows 10/11 (64-bit Intel/AMD) | **PocketGB-Setup-1.1.0.exe** — installer with Start Menu and optional desktop shortcuts |
| Windows (portable) | **PocketGB-Portable-1.1.0.zip** — extract and run |
| Linux x64 | **PocketGB-Linux-x64-1.1.0.tar.gz** — extract and run the PocketGB executable |
| macOS Apple Silicon | **PocketGB-macOS-Apple-Silicon-1.1.0.tar.gz** — extract and open the PocketGB.app bundle |

All builds are self-contained: you do not need to install .NET separately. Linux and macOS require a working OpenGL 3.3-compatible graphics driver. The macOS bundle is ad-hoc signed, not Apple-notarized; when Gatekeeper blocks it, remove the quarantine attribute after extracting:

~~~bash
xattr -dr com.apple.quarantine PocketGB.app
~~~

## Features

- Game Boy (DMG) and Game Boy Color (CGB) emulation.
- ROM browser, drag-and-drop and recent games.
- Direct .gb, .gbc, and .sgb loading, plus ZIP archives containing supported ROMs.
- ZIP extraction is cached safely; replacing an archive with another ROM invalidates the old cache. Battery saves and save states are kept beside the original ZIP, not inside the cache.
- Ten save-state slots per game, with thumbnails and timestamps.
- Quick save (F5) and quick load (F8); number keys 0–9 select the active slot.
- Automatic battery-backed cartridge saves (.sav), including MBC3 RTC data.
- Four audio channels, mute and volume controls, with SDL audio and OpenAL fallback.
- 0.5× / 1× / 2× speed selection and hold-to-fast-forward.
- Configurable keyboard and gamepad bindings.
- Integer scaling, aspect-ratio lock, DMG colour palettes, scanline options, and screenshots.
- Optional CPU, memory, VRAM and sprite debugging tools.
- Drift-resistant frame pacing and lower overhead while the debug window is hidden.

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

Keys and gamepad mappings can be changed in Settings.

## Saves

Save states capture the whole emulator at that moment and are stored as <game>.state0 through <game>.state9. Battery-backed game saves are stored as <game>.sav and are written automatically while playing and when exiting. You can choose a dedicated save folder in Settings.

## Supported files

Open your own legally obtained Game Boy ROM files (.gb, .gbc, or .sgb) directly or inside a .zip archive. When a ZIP contains multiple supported ROMs, PocketGB selects the first entry in a stable order: files at the archive root first, then folders, alphabetically. ROM extraction is limited to 64 MB per entry.

No commercial games, BIOS files, or copyrighted ROMs are included. PocketGB does not currently extract 7z or RAR archives; extract those with your archive utility first.

## Compatibility and performance

- **Windows:** Windows 10 or 11, 64-bit x64 processor, OpenGL 3.3-compatible GPU.
- **Linux:** x64 desktop distribution with OpenGL 3.3 and its normal graphics/audio runtime libraries.
- **macOS:** Apple Silicon, macOS 12 or newer.
- A recent graphics driver is recommended. On Windows, update the Intel/NVIDIA/AMD display driver if the app reports that an OpenGL context or shader cannot be created.
- A software OpenGL driver may work, but hardware acceleration is strongly recommended.

The UI scales with the window, and fractional downscaling is used when the available area is smaller than one native Game Boy screen. Frame pacing uses high-resolution deadlines and only a short final wait, which helps avoid timing drift without busy-waiting for an entire frame.

## Build from source

This branch uses the MIT-licensed [GameboySharp emulator core](https://github.com/sokie/gameboy_sharp), pinned as a Git submodule.

~~~bash
git clone --recurse-submodules --branch pocketgb-emulator https://github.com/siddop422/Pixel-Lab.git PocketGB
cd PocketGB
pwsh ./scripts/Prepare.ps1
dotnet test ./vendor/GameboySharp/GameboySharp.sln -c Release
dotnet publish ./vendor/GameboySharp/GameboySharp.csproj -c Release -r win-x64 --self-contained true -p:AssemblyName=PocketGB -p:Version=1.1.0 -o publish
~~~

To build the Windows setup wizard, install Inno Setup 6 and run PowerShell:

~~~powershell
& "$env:ProgramFiles(x86)\Inno Setup 6\ISCC.exe" /DAppVersion="1.1.0" /DPublishDir="..\publish" .\install\PocketGB.iss
~~~

## Credits and license

The emulation engine is based on [sokie/gameboy_sharp](https://github.com/sokie/gameboy_sharp), licensed under the MIT License. Its copyright and license notice are preserved in vendor/GameboySharp/LICENSE and THIRD-PARTY-NOTICES.md.

PocketGB is an independent community project and is not affiliated with or endorsed by Nintendo.
