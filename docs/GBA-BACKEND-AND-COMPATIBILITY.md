# GBA backend and multi-core compatibility plan

## Current state

PocketGB currently embeds the pinned GameboySharp core. That core emulates the original Game Boy and Game Boy Color only. It cannot execute GBA ARM7TDMI code, and a .gba extension or a graphics-backend change cannot add GBA support.

The uploaded test image was inspected locally: its header title is **balatro-gba**, and it is a 5,061,324-byte .gba image. Its bytes were not committed or uploaded to this repository. The current build is being changed to show .gba files in the file picker and give an explicit unsupported-core message instead of a generic extension error.

## Recommended GBA engine: mGBA

Use the official [mGBA project](https://github.com/mgba-emu/mgba) as a separate native core instead of writing a second CPU/PPU/APU from scratch. The project supports Game Boy Advance as well as original Game Boy and Game Boy Color, includes an HLE BIOS implementation, and is designed to run at full speed on low-end hardware. The upstream core is MPL-2.0 licensed. See the [official mGBA README](https://github.com/mgba-emu/mgba) and the [mGBA core API](https://github.com/mgba-emu/mgba/blob/master/include/mgba/core/core.h).

The mCore API is a vtable shared by the GBA and GB cores. It exposes ROM loading, frame execution, key input, pixel access, audio buffers, and save/load state operations. mCoreFindVF can select the correct platform from a cartridge image. An existing native wrapper demonstrates this same design and documents the different native display sizes: 240×160 for GBA and 160×144 for GB. See [mGBA-wasm core mapping](https://github.com/wasm-gaming/mGBA-wasm/blob/main/CORE.md).

## Required PocketGB architecture changes

Do not make GameWindow depend directly on a Game Boy PPU if the app is to support more than one system. Introduce a small core contract first:

~~~csharp
internal interface IEmulationCore : IDisposable
{
    string SystemName { get; }
    string GameTitle { get; }
    int FrameWidth { get; }
    int FrameHeight { get; }
    double NominalFrameRate { get; }
    bool IsPaused { get; set; }
    ReadOnlyMemory<uint> VideoFrame { get; }
    void LoadRom(string path);
    void SetButtons(uint buttons);
    void RunFrames(int count);
    void Reset();
    byte[] SaveState();
    bool LoadState(ReadOnlySpan<byte> state);
    void SaveBattery();
}
~~~

Implement:
- GameboySharpCoreAdapter around the current GB/GBC Emulator.
- MgbaCoreAdapter around a small, pinned native mGBA C ABI wrapper.
- CoreFactory to detect cartridge type and choose the core in Auto mode.

The UI must read frame dimensions from the selected core. Do not hard-code 160×144 into the renderer: GBA outputs 240×160. The audio adapter must accept the active core's sample rate. GBA controls also need X/Y/L/R mappings in addition to the eight Game Boy buttons.

## Native build and packaging

1. Pin an official mGBA release/commit as a separate source dependency and preserve its MPL-2.0 notices.
2. Build a minimal mgba.dll native library plus a small C ABI shim in CI for win-x64. Do not ship Qt/SDL frontends when only the core API is needed.
3. Expose simple functions for create/destroy, ROM load, run frame, dimensions, pixels, input, audio pull, reset and state serialization.
4. Load the native library from runtimes/win-x64/native; keep the GB/GBC-only executable usable when the GBA core is absent.
5. Do not bundle BIOS dumps or commercial ROM files. mGBA has an HLE BIOS; a user-supplied legal BIOS can be an optional setting.

## Backend settings UX

Only expose choices after each implementation is present and tested:

- **Emulation core:** Auto, GameboySharp (GB/GBC), mGBA (GB/GBC/GBA).
- **Graphics API:** OpenGL (currently implemented); Vulkan only after a real Vulkan renderer and matching ImGui presenter exist.
- **Pixel processing:** GPU shader effects versus CPU compatibility processing. CPU pixel processing still needs a presentation surface; it is not a no-GPU window by itself.

Auto mode should select mGBA for GBA images and GameboySharp for GB/GBC unless the user has explicitly chosen another installed core. A missing core must report exactly which backend is unavailable. Never show a nonfunctional backend as selectable.

## Compatibility and test gates

A goal of broad GBA compatibility is realistic with mGBA, but no emulator should promise every game, peripheral or special cartridge works. Test actual ROMs and publish a compatibility matrix:
- GBA commercial/homebrew suite, including the uploaded Balatro GBA image when testing locally.
- GB/GBC homebrew such as Geometry Dash GB, using the exact ROM version.
- GB/GBC acceptance and timer/PPU tests, plus save-state round trips for both cores.
- Input, audio, save RAM, save states, reset, aspect ratio, 240×160 resizing, turbo, and speed changes.
- Long-run tests for RTC and battery-save persistence.

The native core is deliberately not advertised as available in the current PocketGB build. The required adapter and native packaging must pass CI before that dropdown is added.
