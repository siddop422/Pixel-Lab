# PocketGB

A lightweight Windows Game Boy and Game Boy Color emulator with a polished desktop interface, save-state slots, automatic cartridge saves, and a one-click installer.

## Download

Open the [PocketGB Releases](https://github.com/siddop422/Pixel-Lab/releases) page and download:

- **PocketGB-Setup-1.0.0.exe** — normal Windows installer; adds Start Menu and optional desktop shortcuts.
- **PocketGB-Portable-1.0.0.zip** — extract and run without installing.

The Windows build is self-contained. You do not need to install .NET separately. The current build also applies the compatibility fix for ImGui.NET 1.91.

## Features

- Original Game Boy (DMG) and Game Boy Color (CGB) emulation.
- ROM browser for .gb, .gbc, and .sgb files, plus drag-and-drop and a recent-games list.
- Ten save-state slots per game, with thumbnails and timestamps.
- Quick save (F5) and quick load (F8); number keys 0–9 select the active slot.
- Automatic battery-backed cartridge saves (.sav), including MBC3 RTC data.
- Four audio channels, mute and volume controls.
- 0.5× / 1× / 2× speed selection and hold-to-fast-forward.
- Configurable keyboard and gamepad bindings.
- Integer scaling, aspect-ratio lock, DMG colour palettes, scanline options, and screenshots.
- Optional CPU/memory/VRAM/sprite debugging tools.

## Controls

| Game Boy button | Default keyboard key |
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

Open your own legally obtained Game Boy ROM files (.gb, .gbc, or .sgb). **No commercial games, BIOS files, or copyrighted ROMs are included.**

## Requirements

- Windows 10 or Windows 11, 64-bit.
- OpenGL 3.3-compatible graphics.
- Audio output device.

The installer bundles the .NET runtime and native application dependencies.

## Build from source

This branch uses the MIT-licensed [GameboySharp emulator core](https://github.com/sokie/gameboy_sharp), pinned as a Git submodule.

Run these commands in PowerShell:

    git clone --recurse-submodules --branch pocketgb-emulator https://github.com/siddop422/Pixel-Lab.git PocketGB
    cd PocketGB
    .scriptsPrepare.ps1
    dotnet publish .endorGameboySharpGameboySharp.csproj -c Release -r win-x64 --self-contained true -p:AssemblyName=PocketGB -p:Version=1.0.0 -o publish

To build the setup wizard, install Inno Setup 6 and run:

    iscc /DPublishDir="publish" /DAppVersion="1.0.0" .installPocketGB.iss

## Credits and license

The emulation engine is based on [sokie/gameboy_sharp](https://github.com/sokie/gameboy_sharp), licensed under the MIT License. Its original copyright and license notice are preserved in vendor/GameboySharp/LICENSE and in this repository's THIRD-PARTY-NOTICES.md.

PocketGB is an independent community project and is not affiliated with or endorsed by Nintendo.
