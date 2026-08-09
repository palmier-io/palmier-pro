#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LD_LIBRARY_PATH="$ROOT/.deps/sysroot/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="$ROOT/.deps/sysroot/usr/lib/x86_64-linux-gnu/pkgconfig:$ROOT/.deps/sysroot/usr/lib/pkgconfig:$ROOT/.deps/sysroot/usr/share/pkgconfig"
exec "$ROOT/.deps/sysroot/usr/bin/pkgconf" "$@"
