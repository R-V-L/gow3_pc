# Changelog

Linux support on top of the upstream Windows-focused port. See `docs/LINUX.md` for the details
and the commits for the exact changes.

## Linux

### Added
- **Native Linux build and run path** (`build.sh` Linux branch + `run.sh`), validated on
  Ubuntu 26.04 (NVIDIA, proprietary driver) and the Steam Deck (AMD Van Gogh, Mesa RADV).
- `scripts/launch_env.py` — one source for the graphics options, patch selection and
  `GOW3_DMEM_MB`/`GOW3_VBLANK_HZ`, shared by `run.py` (Windows) and `run.sh` (Linux).
- `packaging/deck.sh` — a self-contained Linux/Steam Deck package (bundled libraries, `RPATH`,
  no system install) plus `packaging/deck-gow3.ini` (800p 16:10 + engine 60 + FSR 1 defaults).
- `Resolution Patch - 800p` — 1280×800. Note the game's projection is 16:9, so this **stretches
  vertically** to fill the Steam Deck's 16:10 panel; 720p letterboxes with the correct aspect.
- `docs/LINUX.md`; CI (build + tests + the Steam Deck package).

### Fixed
- **Frame limit hung the game.** With `fps_limit` set to anything but `0`, the game black-screened
  at startup (GPU idle, guest polling, no crash). The present thread's sub-vblank flip path
  (`immediate_flips`) is now used only when the limit **exceeds** the vblank rate; at or below it
  the outer vblank-paced flip already satisfies the limit. `fps_limit=30/60/120/0` all boot.
- **Corrupted textures and flicker** — `run.sh` now applies `GOW3_UPSCALER=none` and
  `GOW3_READBACK_LINEAR=1`, like `run.py`.
- **Fault while building the heaps** — `run.sh` now derives `GOW3_DMEM_MB` from the selected
  patches (the pool was smaller than the game's allocations).
- `src/actor_hook.h` — C11 `_Static_assert` in a header shared with C++ (GCC rejects it in C++).
- `build.sh` — the `mp3-test` link line was missing `-lm`.
- `tests/test_sema.c` — a negative resolver assertion broken by the gow3 rename.
- **Steam Deck `VK_ERROR_INCOMPATIBLE_DRIVER`** — the package no longer bundles the display/GPU
  stack (`libxcb`/`libX11`/`libdrm`/`libwayland`) that the host's Mesa ICD needs.

### Notes
- Build with `GOW3_LTO=OFF`: conda-forge GCC 16's LTO miscompiles
  `Vulkan::Instance::CreateDevice()`.
