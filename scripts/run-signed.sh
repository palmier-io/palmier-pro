#!/usr/bin/env bash
# Dev loop without the repeating keychain prompt.
#
# `swift run` produces an AD-HOC binary whose code identifier changes every build, so the
# keychain "Always Allow" grant (bound to the app's designated requirement) never matches on
# the next launch — you get re-prompted every time. This builds the same debug binary but
# signs it with a STABLE identity + fixed identifier, giving a cdhash-free requirement that
# persists across rebuilds. Click "Always Allow" once and it sticks.
#
# Unlike scripts/dev.sh this runs the raw binary (not a .app bundle), so it needs no .env
# backend config. Override the identity with SIGNING_IDENTITY=... if desired.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

swift build --package-path "$ROOT"
BIN="$(swift build --package-path "$ROOT" --show-bin-path)/PalmierPro"

# Resolve to the cert's SHA-1 hash, not its name — multiple certs can share a common name
# ("ambiguous" error), but hashes are unique.
IDENTITY="${SIGNING_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk '/Apple Development:/{print $2; exit}')}"

if [ -n "${IDENTITY:-}" ]; then
  echo "==> Signing with stable identity: $IDENTITY" >&2
  codesign --force --timestamp=none --sign "$IDENTITY" --identifier io.palmier.pro "$BIN"
else
  echo "!! No codesigning identity found; launching ad-hoc (keychain will re-prompt)." >&2
fi

exec "$BIN"
