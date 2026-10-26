#!/usr/bin/env bash
# Build dependencies of the release AppImage on Ubuntu 24.04 (.github/workflows/linux-appimage.yml).
# Its glibc (2.39) is the oldest one players can have: SteamOS, Bazzite/Fedora, Debian 13 and
# Ubuntu 24.04 or newer. A build on a rolling distro needs the host's glibc instead (#291).
# What 24.04 lacks or ships too old is built into /usr/local: Vulkan-Headers, VMA, SDL3.
set -euo pipefail
sudo=$([[ $(id -u) == 0 ]] || echo sudo)
# Where the source-built headers and SDL3 go: /usr/local normally, a user-writable prefix in CI
# (so actions/cache can store it; the workflow exports CMAKE_PREFIX_PATH/PKG_CONFIG_PATH/...).
prefix=${SPARTAN_DEPS_PREFIX:-/usr/local}
install_sudo=
if [[ $prefix == /usr/local ]]; then install_sudo=$sudo; fi
mkdir -p "$prefix"
export DEBIAN_FRONTEND=noninteractive
$sudo apt-get update
$sudo apt-get install -y --no-install-recommends \
    build-essential g++-14 gcc-14 cmake ninja-build pkg-config git curl ca-certificates file patchelf binutils ccache nasm \
    libvulkan-dev glslang-tools libboost-dev libfmt-dev libxxhash-dev libzstd-dev libzydis-dev robin-map-dev \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxss-dev libxtst-dev libxfixes-dev \
    libxinerama-dev libxkbcommon-dev libwayland-dev wayland-protocols libdrm-dev libgbm-dev \
    libegl-dev libasound2-dev libpulse-dev libpipewire-0.3-dev libudev-dev libdbus-1-dev libibus-1.0-dev \
    python3
$sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-14 140 --slave /usr/bin/g++ g++ /usr/bin/g++-14
$sudo update-alternatives --install /usr/bin/cc cc /usr/bin/gcc-14 140
$sudo update-alternatives --install /usr/bin/c++ c++ /usr/bin/g++-14 140

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The source-built pieces live in /usr/local and are restored from the CI cache when unchanged;
# skip each build when its files are already there.
# Vulkan-Headers (and Vulkan-Hpp): 24.04 has 1.3.275, the renderer needs 1.4 types.
VULKAN_HEADERS=${VULKAN_HEADERS:-vulkan-sdk-1.4.357.0}
if [[ ! -f $prefix/include/vulkan/vulkan.h ]]; then
    git clone -q --depth 1 -b "$VULKAN_HEADERS" https://github.com/KhronosGroup/Vulkan-Headers "$work/vulkan-headers"
    cmake -S "$work/vulkan-headers" -B "$work/vulkan-headers/build" -G Ninja -DCMAKE_INSTALL_PREFIX="$prefix" >/dev/null
    $install_sudo cmake --install "$work/vulkan-headers/build" >/dev/null
fi
# Vulkan Memory Allocator: header only, not packaged in 24.04.
VMA=${VMA:-v3.1.0}
if [[ ! -f $prefix/include/vk_mem_alloc.h ]]; then
    mkdir -p "$prefix/include"
    $install_sudo curl -fsSL -o "$prefix/include/vk_mem_alloc.h" \
        "https://raw.githubusercontent.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator/$VMA/include/vk_mem_alloc.h"
fi
# SDL3: not packaged in 24.04.
SDL=${SDL:-3.4.16}
if [[ ! -f $prefix/lib/libSDL3.so ]]; then
    curl -fsSL "https://github.com/libsdl-org/SDL/releases/download/release-$SDL/SDL3-$SDL.tar.gz" | tar xz -C "$work"
    cmake -S "$work/SDL3-$SDL" -B "$work/sdl" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_STATIC=OFF \
        -DSDL_WAYLAND_LIBDECOR=OFF >/dev/null
    ninja -C "$work/sdl" >/dev/null
    $install_sudo ninja -C "$work/sdl" install >/dev/null
fi
# FFmpeg: only the decoders/demuxers the game uses. The distro build links every encoder
# (x265/codec2/AV1...) plus librsvg/cairo/pango/ICU and the network libraries, which the
# AppImage then carries.
FFMPEG=${FFMPEG:-6.1.1}
if [[ ! -f $prefix/lib/libavcodec.so.60 ]]; then
    curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG.tar.xz" | tar xJ -C "$work"
    (
        cd "$work/ffmpeg-$FFMPEG"
        ./configure --prefix="$prefix" \
            --disable-everything --disable-autodetect --disable-programs --disable-doc \
            --disable-avdevice --disable-avfilter --disable-postproc \
            --disable-network --disable-encoders --disable-muxers --disable-devices --disable-filters \
            --enable-shared --disable-static --enable-pthreads \
            --enable-avcodec --enable-avformat --enable-avutil --enable-swscale --enable-swresample \
            --enable-protocol=file --enable-demuxer=mov,mp3,wav,ogg,matroska \
            --enable-decoder=h264,hevc,mp3,aac,ac3,eac3,flac,vorbis,opus,pcm_s16le \
            --enable-parser=h264,hevc,aac,mp3 --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb
        make -j"$(nproc)"
        $install_sudo make install
    )
fi
if [[ $prefix == /usr/local ]]; then $sudo ldconfig; fi
