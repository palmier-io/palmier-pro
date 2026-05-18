#!/bin/bash
# scripts/dev.sh — build the debug bundle and open it

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/scripts/bundle.sh" debug --sign
open "$ROOT/.build/PalmierPro.app"
