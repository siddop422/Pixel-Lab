# PocketGB multi-system backend

## Current implementation

PocketGB now includes two real emulation cores on the Windows x64 build:

- **GameboySharp** — the existing managed Game Boy / Game Boy Color core. Auto mode keeps using this for `.gb`, `.gbc`, and `.sgb` cartridges.
- **mGBA** — the pinned native mGBA core for Game Boy Advance and optional GB/GBC playback. Auto mode routes `.gba` cartridges here.

The upstream mGBA source is pinned to commit [431935616c0e216d650b25b2ea0c0acccd359038](https://github.com/mgba-emu/mgba/commit/431935616c0e216d650b25b2ea0c0acccd359038). The build uses mGBA's `LIBMGBA_ONLY` core library with its GBA and GB cores enabled. Qt, SDL desktop frontends, debugger UI, and other optional frontends are not shipped. The native DLL is approximately 855 KB in the validated Windows artifact, and the MPL-2.0 licence notice is included in the portable package.

mGBA uses its HLE BIOS configuration. No commercial BIOS image or game ROM is bundled.

## Selecting the emulation core

Open **Settings → General → Emulation core**:

| Option | Behaviour |
| --- | --- |
| **Auto (recommended)** | `.gba` uses mGBA; `.gb`, `.gbc`, and `.sgb` use GameboySharp |
| **GameboySharp (GB/GBC)** | Use the original PocketGB Game Boy / Color core for GB/GBC games |
| **mGBA (GB/GBC/GBA)** | Use mGBA for supported GBA and GB/GBC cartridges |

GBA images are always routed to mGBA because the GameboySharp core cannot execute ARM7TDMI instructions.

## Display and controls

The mGBA window reads the selected core's current framebuffer dimensions:

- Game Boy / Color: 160×144
- Game Boy Advance: 240×160

It uses the same OpenGL 3.3 presentation path as the rest of PocketGB, with nearest-neighbour pixel-perfect or bilinear filtering. The display scales to fit the window while preserving the correct aspect ratio.

Default keyboard controls in the mGBA window:

| Action | Key |
| --- | --- |
| D-pad | Arrow keys |
| A / B | Z / X |
| Start / Select | Enter / Right Shift |
| L / R | A / S |
| Pause / resume | Space |
| Fast-forward (hold) | Tab |
| Quick save / load | F5 / F8 |
| Reset | F9 |

Gamepad A/B, D-pad, Start/Back and shoulder/trigger buttons are mapped where the connected controller exposes them.

The mGBA window includes one quick-save state per game, battery save data (`.sav`), reset, pause, speed and a top-right overlay which reports render FPS separately from emulated game FPS. The shared frame scheduler supports the same 0.5× / 1× / 2× speed options and configurable Tab turbo multiplier as the GameboySharp window.

## Audio, saves and native runtime

The managed adapter connects to PocketGB's existing SDL or OpenAL audio output. It pulls mGBA's stereo samples and resamples them to the selected output rate. Reusable pixel and audio buffers avoid allocating new large frame arrays on every emulated frame.

Battery data is saved beside the original ROM (or in the configured save folder). mGBA state data is written to a `.state0` file beside that ROM. ZIP archives continue to use PocketGB's ROM cache, while saves remain beside the original ZIP file.

The Windows x64 build includes `pocketgb-mgba.dll`, the native build manifest, and `licenses/mGBA-MPL-2.0.txt`. The build is pinned and reproducible using `scripts/Build-Mgba.ps1`.

## Validation

The Windows CI run [45683839180](https://github.com/siddop422/Pixel-Lab/actions/runs/45683839180) completed successfully:

- 92 tests passed, 0 failed, 7 skipped (99 total).
- Includes a generated synthetic GBA cartridge test which loads through the native mGBA adapter, verifies 240×160 output, runs two frames, and saves/restores a state.
- Native mGBA DLL build, self-contained Windows x64 publish, installer compilation, portable ZIP creation, and checksum generation all passed.
- The portable ZIP contains `pocketgb-mgba.dll` and the MPL-2.0 notice.

The seven skipped tests need optional external Game Boy ROM or CPU-vector datasets which are not bundled with the repository.

## Uploaded Balatro GBA image

The user-provided `balatro-gba-0.2.2.gba` image was inspected locally but was not committed or uploaded to GitHub. Its header contains the GBA entry signature byte `0xEA` at offset `0x03` and the fixed GBA header marker `0x96` at offset `0xB2`, so it matches the cartridge signature checks used by the pinned mGBA version. The exact game was not run in CI; the automated test uses a small generated homebrew-style GBA image instead.

A matching header establishes that mGBA should detect it as a GBA cartridge, but does not guarantee every feature of that particular game works. Please test the installed build with the original file and report any reproducible in-game issue.

## Graphics API status and limitations

The **emulation core** selector is implemented. The **graphics API** is still OpenGL 3.3 only. Vulkan is not listed as available because a separate Vulkan renderer and a Vulkan-compatible ImGui presenter have not been implemented. CPU pixel processing is also not currently a separate display backend; offering it would still require a presentation surface.

mGBA substantially broadens GBA and GB/GBC compatibility, but no emulator can honestly promise every commercial game, peripheral, unusual cartridge, or ROM hack works perfectly. Compatibility should continue to be tested against actual games and homebrew suites.
