#!/usr/bin/env bash
# Preflight for the Developer ID signed release. Exits non-zero with remediation
# when signing prerequisites are missing; never signs or installs anything.
set -u

failures=0

echo "== Codesigning identities =="
identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
count=$(printf '%s' "$identities" | grep -c "valid identities found" || true)
echo "$identities" | head -2
if printf '%s' "$identities" | grep -q "^0 valid identities found"; then
  echo "MISSING: no codesigning identity. Restore/unlock a Developer ID"
  echo "certificate and key through Keychain Access."
  failures=$((failures + 1))
elif printf '%s' "$identities" | grep -q "valid identities found" && ! printf '%s' "$identities" | grep -q "[1-9] valid identit"; then
  echo "MISSING: no valid Developer ID identity."
  failures=$((failures + 1))
fi

echo "== Provision profile =="
if [ -z "${PROVISION_PROFILE:-}" ] && [ ! -f scripts/Palmier_Pro_Developer_ID.provisionprofile ]; then
  echo "MISSING: set PROVISION_PROFILE or place scripts/Palmier_Pro_Developer_ID.provisionprofile."
  failures=$((failures + 1))
fi

echo "== Profile overrides =="
for var in SIGNING_IDENTITY NOTARY_PROFILE; do
  if [ -n "${!var:-}" ]; then echo "$var is set."; else echo "$var not set."; fi
done

echo "== Installed app (untouched until ready) =="
codesign -dv --verbose=4 /Applications/CompositorPro.app 2>&1 | grep -E "Identifier|Authority" | head -4 || echo "/Applications/CompositorPro.app not present"

if [ "$failures" -gt 0 ]; then
  echo "PREFLIGHT: $failures prerequisite(s) missing — signed release NOT attempted."
  exit 1
fi
echo "PREFLIGHT: ready — run the full signed build/install per scripts/bundle.sh."
