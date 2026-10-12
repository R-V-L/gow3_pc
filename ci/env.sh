#!/usr/bin/env bash
# Environment for building and testing the Linux port against a conda prefix. Source it:
#   source ci/env.sh              # uses $CONDA_PREFIX, else ./.deps/env
#
# CI uses it too. The compilers are the conda-forge ones (the binaries are prefixed, so CC/CXX
# are set explicitly). GOW3_LTO=OFF: conda-forge GCC 16's LTO miscompiles
# Vulkan::Instance::CreateDevice() (see docs/LINUX.md).
prefix="${CONDA_PREFIX:-$PWD/.deps/env}"
export PATH="$prefix/bin:$PATH"
export CC="$prefix/bin/x86_64-conda-linux-gnu-gcc"
export CXX="$prefix/bin/x86_64-conda-linux-gnu-g++"
export CMAKE_PREFIX_PATH="$prefix"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
export CPATH="$prefix/include${CPATH:+:$CPATH}"
export LIBRARY_PATH="$prefix/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GOW3_LTO=OFF
