#!/bin/bash
# scripts/dev.sh — build the debug bundle, launch it, and stream its OSLog.
# Usage: scripts/dev.sh [--speech] [--telemetry] [--all] [--no-stream]

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

stream=true
bundle_args=(debug --fast)
for arg in "$@"; do
    case "$arg" in
        --no-stream) stream=false ;;
        *) bundle_args+=("$arg") ;;
    esac
done

"$ROOT/scripts/bundle.sh" "${bundle_args[@]}"

if ! $stream; then
    open "$ROOT/.build/CompositorPro.app"
    exit 0
fi

echo "Streaming OSLog (subsystem=io.compositor.pro). Ctrl-C to quit app and stop." >&2
echo >&2

cleanup() {
    pid=$(pgrep -f "CompositorPro.app/Contents/MacOS/CompositorPro" | head -1 || true)
    if [ -n "$pid" ]; then
        osascript -e 'quit app "CompositorPro"' 2>/dev/null || kill "$pid" 2>/dev/null || true
    fi
}
trap cleanup INT TERM EXIT

( sleep 0.5 && open "$ROOT/.build/CompositorPro.app" ) &
log stream \
    --predicate 'subsystem == "io.compositor.pro"' \
    --level info \
    --style compact
