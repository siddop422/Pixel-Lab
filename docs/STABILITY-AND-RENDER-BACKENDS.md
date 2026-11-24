# PocketGB stability and renderer-backend plan

## 1. Current crash investigation

The screenshot's **KERNEL PANIC** is rendered by the game running inside the Game Boy. It is not, by itself, proof of a Windows or GPU-driver crash. The emulator needs hardware-accuracy tests and a diagnostic report before attributing a game's panic to graphics hardware.

This branch fixes two concrete CGB timing/startup defects found in the pinned core:

- CGB post-boot CPU registers are set to the documented CGB values: `AF=1180`, `BC=0000`, `DE=FF56`, `HL=000D`, `SP=FFFE`, `PC=0100`.
- CGB post-boot bank defaults are VRAM bank 0 (`VBK=FE` readback) and WRAM bank 1 (`SVBK=F8` readback; selector 0 maps to physical bank 1).
- In double-speed mode, the PPU and APU still advance at the Game Boy dot clock, but DIV/TIMA advance at the doubled CPU clock. The frame loop now gives `Timer.Tick` the full CPU-cycle count while retaining the half-rate count for PPU/APU.

The patch is applied by `scripts/Prepare.DisplaySettings.ps1` because the emulator core is a pinned Git submodule. Regression tests are generated in `vendor/GameboySharp/GameboySharp.Tests/CgbStartupRegressionTests.cs` each build.

## 2. Stability test gate

Before a release, run:

```powershell
pwsh ./scripts/Prepare.ps1
dotnet test ./vendor/GameboySharp/GameboySharp.sln -c Release
```

Add freely redistributable test ROMs to CI or a local test folder; do not bundle commercial game ROMs. Recommended suites:

- [Mooneye Test Suite](https://github.com/Gekkio/mooneye-test-suite/) — boot values, CPU, interrupts, timer, OAM DMA and PPU acceptance tests.
- [Blargg Game Boy test ROMs](https://github.com/retrio/gb-test-roms) — CPU instruction, memory and timing tests.
- [Pan Docs — power-up sequence](https://gbdev.io/pandocs/Power_Up_Sequence.html), [timer/divider](https://gbdev.io/pandocs/Timer_and_Divider_Registers.html) and [PPU rendering timing](https://gbdev.io/pandocs/Rendering.html).

A compatibility claim should be based on pass/fail results, not just that a game reaches its title screen. Keep per-ROM results in CI artifacts; tests requiring proprietary ROMs remain opt-in.

## 3. Clean backend architecture

### Current implementation

- `vendor/GameboySharp/UI/GameWindow.cs` creates an OpenGL 3.3 context at window creation and constructs the ImGui OpenGL controller.
- `vendor/GameboySharp/UI/ScreenRenderer.cs` is directly coupled to Silk.NET.OpenGL.
- `vendor/GameboySharp/UI/SettingsDialog.cs` owns the Video tab.
- `vendor/GameboySharp/Config/EmulatorConfig.cs` stores persisted video settings.
- `scripts/Prepare.DisplaySettings.ps1` applies our changes to the pinned submodule during CI/build.

Changing a dropdown alone cannot switch APIs: the window/context, renderer resources, and ImGui rendering backend are all OpenGL-specific today.

### Phase A — renderer interface (keep OpenGL as the safe default)

Introduce a small renderer contract in `vendor/GameboySharp/UI/Rendering/IRenderBackend.cs`:

```csharp
internal interface IRenderBackend : IDisposable
{
    string Name { get; }
    void Initialize();
    void Render(ReadOnlySpan<uint> frameBuffer, int width, int height);
    void Resize(int width, int height);
}
```

Move existing GL setup and drawing from `ScreenRenderer` into `OpenGlRenderBackend`. Keep the emulation core unaware of graphics APIs. The window owns exactly one active backend.

### Phase B — CPU vs GPU processing

Add a separate `VideoProcessingMode` setting with two honest meanings:

- **GPU (default):** keep nearest/bilinear filtering and post-processing in the OpenGL fragment shader.
- **CPU compatibility:** perform scaling and optional colour/LCD effects on a reusable CPU-side pixel buffer, then upload the final buffer to the presentation surface. Reuse buffers; do not allocate a new array every frame.

Important: this first CPU mode still uses the existing OpenGL window to present the finished image. It is a CPU pixel-processing fallback, **not** a no-GPU/no-OpenGL window backend. A genuine no-OpenGL mode would need a separate SDL software-presenter and a matching UI/input host.

### Phase C — Vulkan backend

Add `Silk.NET.Vulkan` only when implementing the backend, not just to show a nonfunctional selector. Create `VulkanRenderBackend` with:

1. Vulkan-capable window options and required surface extensions.
2. Vulkan instance, physical/logical device and graphics queue selection.
3. Swapchain and image views; recreate them after resize/out-of-date events.
4. Render pass, graphics pipeline, descriptor sets, vertex/index buffers and texture upload.
5. Command buffers plus image-available/render-finished semaphores and fences.
6. SPIR-V versions of the simple screen shaders.
7. A Vulkan-compatible ImGui renderer (the existing `ImGuiController` is OpenGL-specific).

Useful implementation references:
- [Silk.NET Vulkan pipeline discussion](https://github.com/dotnet/Silk.NET/discussions/601) — the maintainers describe using Vulkan window options, `window.VkSurface`, and caching the `Vk` API object.
- [Silk.NET Windowing](https://github.com/dotnet/Silk.NET/tree/main/src/Windowing) — context and platform-window integration.

Vulkan and OpenGL must be separate implementations behind `IRenderBackend`; do not call GL methods from Vulkan mode.

### Phase D — simple settings UX

In `SettingsDialog.DrawVideoTab()`, group settings as:

- **Graphics API:** Auto / OpenGL / Vulkan (show Vulkan as selectable only after it passes the backend smoke tests on the current build; otherwise show “not available in this build”).
- **Pixel processing:** GPU / CPU compatibility.
- **Scaling:** Pixel-perfect / Bilinear / Sharp bilinear.
- **Effects:** LCD grid, scanlines, CRT, brightness and saturation.

Persist the selection in `VideoConfig`. Because the API is chosen while creating the window, show “Restart PocketGB to apply” after changing Graphics API. Auto should try Vulkan only when the Vulkan backend is shipped and validated; otherwise use OpenGL. If backend initialization fails, log the reason, dispose partial resources and fall back to OpenGL. Never silently label an OpenGL renderer as Vulkan.

## 4. Release criteria

1. CGB startup and double-speed regression tests pass.
2. Mooneye timer, boot-register, PPU and OAM-DMA subsets pass where ROMs are available.
3. Existing DMG/CGB screenshot tests stay pixel-identical when no new effects are enabled.
4. OpenGL smoke test passes on Intel UHD-class hardware.
5. CPU-processing mode passes identical framebuffer/output tests.
6. Vulkan mode is exposed only after Windows build, device creation, swapchain resize, present, device-loss/fallback and ImGui tests pass.
7. A game panic report includes ROM title/hash, model mode, CPU registers/PC, PPU LY/STAT/LCDC/SCX/SCY, timer registers, CGB speed/bank state, renderer name and recent log lines. It must not include the ROM file contents.

## 5. Scope deliberately deferred

A fully dot/FIFO-accurate PPU, all OAM DMA timing quirks, STOP speed-switch stalls, all uncommon cartridge mappers, SGB and GBA support are larger projects. Do not fold them into a quick Vulkan toggle. The current scanline PPU is not a drop-in substitute for a dot-accurate renderer.
