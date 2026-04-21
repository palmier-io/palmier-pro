#!/bin/bash
set -euo pipefail

# Usage:
#   scripts/bundle.sh [release|debug]           # dev build (no signing)
#   scripts/bundle.sh release --sign            # build + codesign
#   scripts/bundle.sh release --dist            # build + sign + notarize + staple + DMG

CONFIG="release"
MODE="dev"
for arg in "$@"; do
  case "$arg" in
    release|debug) CONFIG="$arg" ;;
    --sign)        MODE="sign" ;;
    --dist)        MODE="dist" ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Palmier, Inc. (MMFLRC7562)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-palmier-notary}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES="$ROOT/Sources/PalmierPro/Resources"
APP="$ROOT/.build/PalmierPro.app"
ZIP="$ROOT/.build/PalmierPro.zip"
DMG="$ROOT/.build/PalmierPro.dmg"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/PalmierPro"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PalmierPro"
cp "$RESOURCES/Info.plist" "$APP/Contents/Info.plist"
cp "$RESOURCES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
touch "$APP"

if [ "$MODE" = "dev" ]; then
  echo "==> Done: $APP (unsigned)"
  exit 0
fi

echo "==> Codesigning (hardened runtime, secure timestamp)"
codesign --force --options runtime --timestamp \
  --sign "$SIGNING_IDENTITY" \
  "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [ "$MODE" = "sign" ]; then
  echo "==> Done: $APP (signed, not notarized)"
  exit 0
fi

echo "==> Zipping .app for notarization"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary (this can take several minutes)"
xcrun notarytool submit "$ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Stapling ticket to .app"
xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "==> Building DMG"
rm -f "$DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/PalmierPro.app"
ln -s /Applications "$STAGING/Applications"
cp "$RESOURCES/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
hdiutil create \
  -volname "Palmier Pro" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG"
rm -rf "$STAGING"

echo "==> Codesigning DMG"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"

echo "==> Submitting DMG to notary"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Stapling DMG"
xcrun stapler staple "$DMG"

echo ""
echo "==> Done"
echo "   App: $APP"
echo "   DMG: $DMG"
