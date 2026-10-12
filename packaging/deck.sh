#!/usr/bin/env bash
# Builds dist/gow3-deck/: a self-contained port for the Steam Deck (or any x86-64 Linux with
# a Vulkan driver). Bundles every shared library the binaries need, except glibc, the Vulkan
# loader and the display/GPU stack (the host's Mesa ICD must be used).
#
# The archive IS the port folder: the user extracts it and drops their game dump inside, so
#   <folder>/bin/ scripts/ patches/ run.sh start-gow3.sh ...
#   <folder>/CUSA01623/   <- the game
#
# Build first: bash build.sh
set -euo pipefail
cd -- "$(dirname -- "$0")/.."

[[ -f out/gow3-probe && -f out/gpu/libgow3gpu.so ]] || { echo 'Build first: bash build.sh' >&2; exit 1; }

# Where the folder will live on the Deck (used for the .desktop entry; override if elsewhere).
deck_dir="${GOW3_DECK_DIR:-/home/deck/Games/gow_3}"

dist=dist/gow3-deck
rm -rf "$dist"
mkdir -p "$dist/bin/gpu" "$dist/bin/lib" "$dist/scripts" "$dist/patches"

install -m755 out/gow3-probe "$dist/bin/gow3-probe"
install -m755 out/gow3-gpu-capabilities "$dist/bin/gow3-gpu-capabilities"
install -m755 out/gpu/libgow3gpu.so "$dist/bin/gpu/libgow3gpu.so"
install -m644 run.sh "$dist/run.sh"
cp scripts/*.py "$dist/scripts/"
cp patches/*.xml "$dist/patches/" 2>/dev/null || true
[[ -f launcher/gow3.png ]] && cp launcher/gow3.png "$dist/gow3.png"
[[ -f packaging/deck-gow3.ini ]] && cp packaging/deck-gow3.ini "$dist/gow3.ini.example"

# Shared libraries: everything the binaries resolve, minus glibc and the Vulkan loader.
echo "Collecting shared libraries..."
ldd out/gow3-probe out/gow3-gpu-capabilities out/gpu/libgow3gpu.so 2>/dev/null \
    | awk '/=>/{print $3}' | grep '^/' | sort -u \
    | while read -r lib; do
        case "$(basename "$lib")" in
            # glibc and the Vulkan loader come from the host.
            libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libresolv.so.*|\
            libnsl.so.*|libutil.so.*|ld-linux-*|libvulkan.so.*) continue ;;
            # The display/GPU stack must come from the host too: the host's Mesa ICD loads the
            # host's libxcb/libdrm, and a bundled (older) copy already in the process makes the
            # ICD fail to load (undefined xcb_dri3_* symbols -> VK_ERROR_INCOMPATIBLE_DRIVER).
            libX11*|libxcb*|libXau*|libXdmcp*|libXext*|libXfixes*|libXrandr*|libXrender*|\
            libxshmfence*|libdrm*|libwayland*|libxkbcommon*) continue ;;
        esac
        cp -L "$lib" "$dist/bin/lib/"
    done
echo "  $(ls "$dist/bin/lib" | wc -l) libraries bundled"

# Our binaries get their own search path (RPATH) instead of LD_LIBRARY_PATH: the host's Vulkan
# loader and Mesa ICD must keep using the host's libraries. A bundled libdrm/libX11/libz under
# LD_LIBRARY_PATH shadows them and the ICD fails to load (vkCreateInstance ->
# VK_ERROR_INCOMPATIBLE_DRIVER). DT_RUNPATH is not inherited by the dlopen'd ICD, so it is safe.
patchelf --set-rpath '$ORIGIN/gpu:$ORIGIN/lib' "$dist/bin/gow3-probe"
patchelf --set-rpath '$ORIGIN/lib' "$dist/bin/gow3-gpu-capabilities"
patchelf --set-rpath '$ORIGIN:$ORIGIN/../lib' "$dist/bin/gpu/libgow3gpu.so"

cat > "$dist/start-gow3.sh" <<'LAUNCH'
#!/usr/bin/env bash
# Starts God of War III. Double-click this (choose Execute) or the .desktop file.
# The game dump lives in this same folder (CUSA01623/); set GOW3_GAME_DIR to use another.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
export GOW3_PREBUILT=1
export GOW3_PROBE="$HERE/bin/gow3-probe"
export GOW3_DATA_DIR="${GOW3_DATA_DIR:-$HOME/.local/share/gow3}"
# Find the game: GOW3_GAME_DIR, CUSA01623/ here, else any subfolder holding an eboot.bin.
if [[ -z ${GOW3_GAME_DIR:-} || ! -f ${GOW3_GAME_DIR:-/nonexistent}/eboot.bin ]]; then
    for candidate in "$HERE/CUSA01623" "$HERE"/*/; do
        if [[ -f ${candidate%/}/eboot.bin ]]; then
            export GOW3_GAME_DIR="${candidate%/}"
            break
        fi
    done
fi
export GOW3_GAME_DIR="${GOW3_GAME_DIR:-$HERE/CUSA01623}"
mkdir -p "$GOW3_DATA_DIR"
cd "$HERE"
exec bash "$HERE/run.sh" "$@"
LAUNCH
chmod 755 "$dist/start-gow3.sh"

cat > "$dist/God of War III.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=God of War III
Comment=God of War III Remastered (native port)
Exec=__DIR__/start-gow3.sh
Path=__DIR__
Icon=__DIR__/gow3.png
Terminal=false
Categories=Game;
DESKTOP
sed -i "s#__DIR__#$deck_dir#g" "$dist/God of War III.desktop"
chmod 755 "$dist/God of War III.desktop"

cat > "$dist/README-DECK.txt" <<'README'
God of War III — Steam Deck

This folder IS the port. Put your game dump in it:

    <this folder>/
      bin/  scripts/  patches/  run.sh  start-gow3.sh  ...
      CUSA01623/        <- your game (the folder with eboot.bin)

Run:
  - Double-click "God of War III.desktop", or
  - Double-click "start-gow3.sh" (choose Execute), or
  - From a terminal:  bash start-gow3.sh

Updating: extract a new version over this folder; it contains no CUSA01623/, so your game is
kept. Saves, shader/pipeline cache and last_run.log go to ~/.local/share/gow3.

The game folder is found automatically (CUSA01623/ here, or any subfolder with eboot.bin);
override with GOW3_GAME_DIR. Nothing is installed system-wide; the host's Vulkan driver is used.
README

echo "Built $PWD/$dist"
du -sh "$dist"
