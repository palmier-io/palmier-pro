#!/usr/bin/env bash
# Source before cargo test when using the local .deps FFmpeg sysroot.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PKG_CONFIG="$ROOT/scripts/pkgconf-wrapper.sh"
export PKG_CONFIG_PATH="$ROOT/.deps/sysroot/usr/lib/x86_64-linux-gnu/pkgconfig:$ROOT/.deps/sysroot/usr/lib/pkgconfig:$ROOT/.deps/sysroot/usr/share/pkgconfig"
export LIBCLANG_PATH="$ROOT/.deps/sysroot/usr/lib/llvm-21/lib"
export BINDGEN_EXTRA_CLANG_ARGS="-I/usr/lib/gcc/x86_64-linux-gnu/15/include -I/usr/include"
# Only for running linked binaries. Do not export this while invoking rustc/clippy.
export PALMIER_RUN_LD_LIBRARY_PATH="$ROOT/.deps/sysroot/usr/lib/x86_64-linux-gnu:$ROOT/.deps/sysroot/usr/lib/llvm-21/lib"
