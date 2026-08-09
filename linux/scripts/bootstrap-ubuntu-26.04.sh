#!/usr/bin/env bash
# Install build and runtime dependencies for Palmier Pro on Ubuntu 26.04 x86_64.
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This bootstrap script targets Linux only." >&2
  exit 1
fi

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "26.04" ]]; then
    echo "Warning: expected Ubuntu 26.04, found ${PRETTY_NAME:-unknown}." >&2
  fi
fi

if [[ "${EUID}" -ne 0 ]]; then
  SUDO=(sudo)
else
  SUDO=()
fi

export DEBIAN_FRONTEND=noninteractive

"${SUDO[@]}" apt-get update
"${SUDO[@]}" apt-get install -y --no-install-recommends \
  build-essential \
  ca-certificates \
  clang \
  cmake \
  curl \
  ffmpeg \
  git \
  libasound2-dev \
  libayatana-appindicator3-dev \
  libavcodec-dev \
  libavdevice-dev \
  libavfilter-dev \
  libavformat-dev \
  libavutil-dev \
  libgtk-3-dev \
  libjavascriptcoregtk-4.1-dev \
  libsecret-1-dev \
  libsoup-3.0-dev \
  libssl-dev \
  libswresample-dev \
  libswscale-dev \
  libwebkit2gtk-4.1-dev \
  libxdo-dev \
  pkg-config \
  patchelf \
  python3 \
  wget

if ! command -v rustup >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none
  # shellcheck disable=SC1091
  source "${HOME}/.cargo/env"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
(
  cd "${LINUX_ROOT}"
  rustup show active-toolchain >/dev/null 2>&1 || rustup toolchain install
  rustup component add rustfmt clippy
)

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is required for the Tauri frontend. Install Node 22+ and re-run." >&2
  exit 1
fi

echo "Bootstrap complete."
echo "Next:"
echo "  cd ${LINUX_ROOT}"
echo "  cargo test --workspace --exclude palmier-app"
echo "  cargo check -p palmier-app"
echo "  cd app && npm ci && npm test && npm run build"
echo "  cd app && npm run tauri:dev"
echo
echo "Runtime requirements:"
echo "  - Distro FFmpeg 8 shared libraries (libav*)"
echo "  - Secret Service / libsecret for BYOK provider keys"
echo "  - GTK 3 and WebKitGTK 4.1 for the Tauri shell"
