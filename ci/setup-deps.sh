#!/usr/bin/env bash
# Builds the three packages conda-forge lacks (or ships too old) into a prefix:
#   robin-map, Zydis (+ its Zycore), and Vulkan-Headers v1.4.363.
#
# Usage: ci/setup-deps.sh [prefix]     (default: $CONDA_PREFIX)
# Needs the conda C/C++ compilers in CC/CXX and cmake + ninja in PATH.
set -euo pipefail

prefix="${1:-${CONDA_PREFIX:?pass a prefix or set CONDA_PREFIX}}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

configure() { cmake -G Ninja -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_BUILD_TYPE=Release "$@"; }

echo "robin-map"
git clone -q --depth 1 https://github.com/Tessil/robin-map.git
configure -S robin-map -B robin-map/build
ninja -C robin-map/build install

echo "Zydis + Zycore"
git clone -q --recursive --shallow-submodules --depth 1 https://github.com/zyantific/zydis.git
configure -S zydis/dependencies/zycore -B zydis/dependencies/zycore/build -DZYAN_BUILD_TESTS=OFF
ninja -C zydis/dependencies/zycore/build install
configure -S zydis -B zydis/build -DZYDIS_BUILD_TOOLS=OFF -DZYDIS_BUILD_EXAMPLES=OFF
ninja -C zydis/build install

echo "Vulkan-Headers v1.4.363"
git clone -q --depth 1 --branch v1.4.363 https://github.com/KhronosGroup/Vulkan-Headers.git
configure -S Vulkan-Headers -B Vulkan-Headers/build \
    -DVULKAN_HEADERS_ENABLE_MODULE=OFF -DVULKAN_HEADERS_ENABLE_TESTS=OFF
ninja -C Vulkan-Headers/build install

echo "Done -> $prefix"
