#!/usr/bin/env bash
# Linux build dependencies in a project-local folder, without sudo.
#
# The release AppImage uses packaging/linux/ci-deps.sh on Ubuntu 24.04. This script reproduces
# the version-sensitive parts on a development machine so `build.sh` can be tested before pushing:
# the distro packages the host does not have, Vulkan-Headers 1.4.357, FFmpeg with the decoders the
# port uses (including PNG for save/trophy icons) and SDL3 when the host package is missing.
# Everything goes to .deps/ (gitignored); source .deps/env.sh before building.
#
# The host still needs the ordinary desktop development packages (X11, Wayland, SDL3's own
# dependencies, audio, dbus); install them with the distro's package manager. This script only
# avoids sudo for the packages that must match the release build.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
deps=${SPARTAN_DEPS_DIR:-$root/.deps}
prefix=$deps/usr
debs=$deps/debs
src=$deps/src
mkdir -p "$debs" "$prefix" "$src"

for tool in apt-get dpkg-deb cmake ninja pkg-config git curl tar; do
    command -v "$tool" >/dev/null || { echo "Need $tool." >&2; exit 1; }
done

# The first dependency of a meta package, e.g. libboost-dev -> libboost1.90-dev. The versioned
# names change between Ubuntu releases, so ask apt instead of hard-coding them.
depends() {
    apt-cache depends --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces \
        --no-enhances "$1" 2>/dev/null | awk '/^ +Depends: /{print $2}'
}
boost_dev=$(depends libboost-dev | grep -E '^libboost[0-9.]+-dev$' | head -1)
zydis_lib=$(depends libzydis-dev | grep -E '^libzydis[0-9]' | head -1)
zycore_lib=$(depends libzycore-dev | grep -E '^libzycore[0-9]' | head -1)
: "${boost_dev:?cannot resolve libboost-dev on this host}"
: "${zydis_lib:?cannot resolve libzydis-dev on this host}"
: "${zycore_lib:?cannot resolve libzycore-dev on this host}"

packages=(
    libvulkan-dev libvulkan1
    libfmt-dev libfmt10
    "$boost_dev"
    robin-map-dev
    libxxhash-dev libxxhash0
    libzydis-dev "$zydis_lib" libzycore-dev "$zycore_lib"
    libzstd-dev libzstd1
    libvulkan-memory-allocator-dev
    nasm glslang-tools spirv-tools
)

# apt-get download fetches a package even when it is installed, without touching the system.
(cd "$debs" && apt-get download "${packages[@]}")

# Extract every .deb into the project prefix. A dev package's .so symlinks point at the runtime
# libraries the host already has; the headers and CMake/pkg-config files are what the build needs.
for deb in "$debs"/*.deb; do
    dpkg-deb -x "$deb" "$prefix"
done

# Vulkan-Headers: Ubuntu's headers are too old for the renderer (mixed float dot product and
# friends). Keep the loader library from libvulkan-dev and replace only the headers.
vulkan_headers=${VULKAN_HEADERS:-vulkan-sdk-1.4.357.0}
if ! grep -q 'VK_HEADER_VERSION 357' "$prefix/include/vulkan/vulkan_core.h" 2>/dev/null; then
    if [[ ! -d $src/Vulkan-Headers/.git ]]; then
        git clone -q --depth 1 -b "$vulkan_headers" https://github.com/KhronosGroup/Vulkan-Headers \
            "$src/Vulkan-Headers"
    fi
    cmake -S "$src/Vulkan-Headers" -B "$src/Vulkan-Headers/build" -G Ninja \
        -DCMAKE_INSTALL_PREFIX="$prefix" >/dev/null
    cmake --install "$src/Vulkan-Headers/build" >/dev/null
fi

# SDL3: Ubuntu 24.04 does not package it. Skip when the host already has a usable sdl3.pc.
if ! pkg-config --exists sdl3; then
    sdl=${SDL:-3.4.16}
    if [[ ! -f $prefix/lib/libSDL3.so ]]; then
        if [[ ! -d $src/SDL3-$sdl ]]; then
            curl -fsSL "https://github.com/libsdl-org/SDL/releases/download/release-$sdl/SDL3-$sdl.tar.gz" |
                tar xz -C "$src"
        fi
        cmake -S "$src/SDL3-$sdl" -B "$src/sdl" -G Ninja -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$prefix" -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
            -DSDL_TEST_LIBRARY=OFF -DSDL_STATIC=OFF -DSDL_WAYLAND_LIBDECOR=OFF >/dev/null
        ninja -C "$src/sdl" >/dev/null
        cmake --install "$src/sdl" >/dev/null
    fi
fi

# FFmpeg: only the decoders the port uses. The distro build links every encoder and the network
# libraries; the AppImage would carry them. PNG needs zlib (save and trophy icons).
ffmpeg=${FFMPEG:-6.1.1}
if [[ ! -f $prefix/lib/libavcodec.so.60 ]]; then
    if [[ ! -f $src/ffmpeg-$ffmpeg.tar.xz ]]; then
        curl -fsSL -o "$src/ffmpeg-$ffmpeg.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$ffmpeg.tar.xz"
    fi
    if [[ ! -d $src/ffmpeg-$ffmpeg ]]; then
        tar xJf "$src/ffmpeg-$ffmpeg.tar.xz" -C "$src"
    fi
    (
        cd "$src/ffmpeg-$ffmpeg"
        PATH="$prefix/bin:$PATH" ./configure --prefix="$prefix" \
            --disable-everything --disable-autodetect --disable-programs --disable-doc \
            --disable-avdevice --disable-avfilter --disable-postproc \
            --disable-network --disable-encoders --disable-muxers --disable-devices --disable-filters \
            --enable-shared --disable-static --enable-pthreads \
            --enable-avcodec --enable-avformat --enable-avutil --enable-swscale --enable-swresample \
            --enable-zlib --enable-protocol=file --enable-demuxer=mov,mp3,wav,ogg,matroska \
            --enable-decoder=h264,hevc,mp3,aac,ac3,eac3,flac,vorbis,opus,pcm_s16le,png \
            --enable-parser=h264,hevc,aac,mp3 --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb
        make -j"$(nproc)"
        make install
    )
fi

cat > "$deps/env.sh" <<EOF
# Source this for a local build: . .deps/env.sh
export SPARTAN_LOCAL_DEPS="$prefix"
P="\$SPARTAN_LOCAL_DEPS"
export PATH="\$P/bin:\$PATH"
export PKG_CONFIG_PATH="\$P/lib/pkgconfig:\$P/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}"
export CMAKE_PREFIX_PATH="\$P/lib/x86_64-linux-gnu/cmake:\$P/share/cmake:\$P\${CMAKE_PREFIX_PATH:+:\$CMAKE_PREFIX_PATH}"
export CMAKE_INCLUDE_PATH="\$P/include\${CMAKE_INCLUDE_PATH:+:\$CMAKE_INCLUDE_PATH}"
export CMAKE_LIBRARY_PATH="\$P/lib/x86_64-linux-gnu:\$P/lib\${CMAKE_LIBRARY_PATH:+:\$CMAKE_LIBRARY_PATH}"
export CPATH="\$P/include\${CPATH:+:\$CPATH}"
export LIBRARY_PATH="\$P/lib:\$P/lib/x86_64-linux-gnu\${LIBRARY_PATH:+:\$LIBRARY_PATH}"
export LD_LIBRARY_PATH="\$P/lib:\$P/lib/x86_64-linux-gnu\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export BOOST_ROOT="\$P"
export VULKAN_SDK="\$P"
export SPARTAN_IN_NIX_SHELL=1
EOF

echo "Local dependencies: $prefix"
echo "Next: . .deps/env.sh && SPARTAN_LTO=OFF bash build.sh"
