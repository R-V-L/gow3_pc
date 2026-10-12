# Linux — play, build and run

The port runs on Linux through the same native probe and `run.sh` used on Windows, with no
launcher GUI. Validated on Ubuntu 26.04 (NVIDIA RTX 4070 SUPER, proprietary driver) and on the
**Steam Deck** (AMD Van Gogh, Mesa RADV). The code path is vendor-neutral Vulkan; Mesa
RADV/ANV and the proprietary NVIDIA driver both work.

## Using a release (Steam Deck or any Linux)

The release archive **is** the port folder. Three steps:

1. **Download** the release (`gow3-linux-x86_64.tar.gz`) and extract it anywhere.
2. **Put your game dump inside it** — the folder that has `eboot.bin` (e.g. `CUSA01623/`),
   next to `bin/`.
3. **Run** `start-gow3.sh` (any Linux), or `start-gow3-deck.sh` / double-click
   `God of War III.desktop` on the Steam Deck.

```
gow_3/
  bin/ scripts/ patches/ run.sh
  start-gow3.sh            # any Linux
  start-gow3-deck.sh       # Steam Deck: writes the tuned preset on first run
  gow3-deck.ini            # the Steam Deck preset
  "God of War III.desktop"
  CUSA01623/               <- your game (the folder with eboot.bin)
```

The game folder is found automatically (`CUSA01623/`, or any subfolder holding an `eboot.bin`);
set `GOW3_GAME_DIR` to point elsewhere. Saves, shader/pipeline cache, `gow3.ini` and
`last_run.log` go to `~/.local/share/gow3`. Extracting a newer release over the folder keeps
`CUSA01623/` (the archive never contains it). The host's Vulkan driver is used; nothing is
installed system-wide.

**First launch compiles shaders** (the cache starts empty), so give it a minute or two before
judging the frame rate.

### Steam Deck performance

The Deck panel is 1280×800, so the Deck launcher writes a tuned preset (see `gow3-deck.ini`):
`render_resolution=720p` (the game is 16:9, so the presenter letterboxes it into the 16:10 panel
with small black bars), `engine_fps=60`, `fps_limit=60`. FSR 1 and RCAS are enabled but idle at
720p: the upscaler only runs when **both** output dimensions are larger, and the 16:9 image is
already 1280 wide like the panel. Drop `render_resolution` to `480p` for more headroom — FSR 1
then engages and upscales back to the panel; for less, raise `engine_fps` to 120.

> **16:10 note.** There is a `Resolution Patch - 800p` (1280×800) for the panel, but the game's
> projection is 16:9: it changes only the output size, so 16:10 **fills the panel by stretching
> vertically** rather than rendering a true 16:10 image. Use 720p (correct aspect, letterboxed)
> unless you prefer filling over aspect.
The in-game menu (**Insert**, or **R3+L2**) changes these (render resolution and engine FPS apply
with "Apply and restart").

**Experimental draw predication.** `GOW3_PREDICATION=1` emulates `IT_SET_PREDICATION` with
`VK_EXT_conditional_rendering` and GPU-side ZPASS occlusion queries, so draws the game marks
occluded are skipped on the GPU. It is off by default because its visual result has not been
validated on hardware yet; enable it to test (on the Deck in particular) and compare frame rates
with `GOW3_FRAME_STATS=1`. It fails open when `VK_EXT_conditional_rendering` is unavailable.

## Build from source

Dependencies are local and need no root: a micromamba prefix under `.deps/` plus three small
source builds. Source the environment (also used by CI):

```bash
source ci/env.sh               # CC/CXX, CMAKE_PREFIX_PATH, PKG_CONFIG_PATH, LD_LIBRARY_PATH, GOW3_LTO=OFF
```

Create the prefix (this is what CI does, in `ci/`):

```bash
.deps/bin/micromamba create -y -p .deps/env -c conda-forge --override-channels \
  gcc_linux-64 gxx_linux-64 sysroot_linux-64 binutils_impl_linux-64 \
  cmake ninja make pkg-config \
  libvulkan-loader vulkan-headers vulkan-tools \
  sdl3 ffmpeg xxhash \
  xorg-libx11 xorg-libxcb xorg-xorgproto xorg-libxext xorg-libxrandr xorg-libxau xorg-libxdmcp \
  wayland libxkbcommon \
  boost-cpp fmt vulkan-memory-allocator \
  glslang spirv-tools spirv-headers spirv-cross xbyak
```

conda-forge has no `zydis`, `robin-map`, or a new enough `Vulkan-Headers`, so those are built
from source into the same prefix (see `ci/setup-deps.sh`): `robin-map`, `Zydis` (+ `Zycore`),
and `Vulkan-Headers` **v1.4.363** (the conda package is 1.3.231 and lacks
`vk::DriverId::eMesaKosmickrisp`, `vk::PipelineBinaryKeyKHR` and the 1.4 core structs).

Then build and run:

```bash
git submodule update --init --recursive     # first time only
bash build.sh

# Offline check: every PS4 import the game uses is implemented (needs the game, no GPU).
out/gow3-probe out/boot-linked.bin --app0 /path/to/CUSA01623 --check-imports

GOW3_GAME_DIR=/path/to/CUSA01623 bash run.sh
```

`run.sh` prepares the image, links libc/libSceFios2, applies the patches and starts the probe. It
derives `GOW3_DMEM_MB` and `GOW3_VBLANK_HZ` from the selected patches' notes via the shared
`scripts/launch_env.py`, exactly as the Windows `run.py` does.

Fallbacks: `GOW3_AUDIO=none bash run.sh` (silent audio), `bash run.sh --software` (lavapipe, the
vendor-neutral proxy).

### Build the Linux / portable package

```bash
bash packaging/linux.sh       # -> dist/gow3-linux/ (the port folder)
```

## Tests

```bash
python3 -m unittest discover -s tests     # scripts and runtime helpers
bash build.sh --test                      # pad, runtime, file-mods, sema, content, mp3, videodec, services
```

## Notes

- **LTO must be off.** `build.sh` defaults `GOW3_LTO=ON` on Linux; with the conda-forge GCC 16
  toolchain that miscompiles `Vulkan::Instance::CreateDevice()` (it clobbers `this` and faults
  at `vk_instance.cpp:656`). The Windows path already defaults LTO off.
- **Direct memory.** The retail pool is 5056 MiB. The texture-fix/resolution patches ask for
  more; without it the game's direct-memory allocations run past the pool and it faults while
  building its heaps. `run.sh` sets `GOW3_DMEM_MB` from the patch notes (7104 MiB for the default
  patch set, higher for 4K).
- **Pipeline binary disk cache** works on Linux (disabled automatically when the loader cannot
  dispatch `VK_KHR_pipeline_binary`).
- Saves and the shader/pipeline cache go to `$GOW3_DATA_DIR/user` (the packaged port sets
  `GOW3_DATA_DIR=~/.local/share/gow3`).

## What was fixed (and why)

The Linux path existed upstream (the base project is a native Linux port) but had bit-rotted on
this Windows-focused fork. What was needed to make it build **and behave** correctly:

1. **Build drift**
   - `src/actor_hook.h` used C11 `_Static_assert` in a header shared with C++ (`gow3_overlay.cpp`,
     `gow3_actors.cpp`). Clang (the Windows toolchain) tolerates it in C++; GCC does not. It now
     maps to `static_assert` under `__cplusplus`.
   - `build.sh`'s `mp3-test` link line was missing `-lm` (`libatrac9` needs `pow`).
   - `tests/test_sema.c`: the negative resolver assertions had been rewritten to a canonical
     `#libkernel` name by the gow3 rename, so they contradicted the positive assertions two lines
     above; restored to a non-canonical scope plus an unknown library.

2. **The two entry points had drifted.** `run.sh` (Linux) was a stale twin of `run.py`
   (Windows): it never applied the game's graphics defaults (`GOW3_UPSCALER=none`,
   `GOW3_READBACK_LINEAR=1`) or the patch-derived `GOW3_DMEM_MB`. The symptoms were **corrupted
   textures** (missing linear readbacks), **flicker** (FSR 3.1 on with uncalibrated motion
   vectors) and a **fault while building the heaps** (pool too small). Fixed by extracting one
   shared `scripts/launch_env.py` that both entry points use.

3. **Frame limiter stalled the guest (black screen).** With `fps_limit` set to anything other
   than `0`, the game hung at startup: a black window, the GPU idle, and no crash — the guest
   sat in a `sceKernelUsleep` poll loop and never submitted a frame. The cause was the present
   thread's **sub-vblank flip path** (`immediate_flips` in
   `gpu/shadps4/core/libraries/videoout/driver.cpp`). It is now used only when the limit
   **exceeds** the vblank rate; at or below it, the outer vblank-paced flip already satisfies the
   limit. Found by bisecting `gow3.ini` setting by setting with "reaches the video stream" as the
   pass/fail signal (`display_mode`, `vsync`, `async_shaders` pass; `fps_limit` hung).

4. **Steam Deck packaging.** The release bundles every shared library the binaries need
   (`bin/lib`, `RPATH` `$ORIGIN/gpu:$ORIGIN/lib`) **except** glibc, the Vulkan loader, and the
   display/GPU stack (`libX11*`, `libxcb*`, `libdrm*`, `libwayland*`, `libxkbcommon*`). Bundling
   an older copy of those under `LD_LIBRARY_PATH` shadows the host's and the Mesa ICD fails to
   load (`undefined symbol: xcb_dri3_get_supported_modifiers_window_modifiers` →
   `VK_ERROR_INCOMPATIBLE_DRIVER`), so the ICD and the port share the host's copy.

5. **Deck preset.** `packaging/gow3-deck.ini` (used by `start-gow3-deck.sh`): 720p render + engine
   60 + FSR 1 (the stock defaults — 1080p render and the 120 FPS engine patch — are too heavy for
   Van Gogh). A `Resolution Patch - 800p` exists too, but the game's 16:9 projection makes it
   stretch to fill the 16:10 panel.
