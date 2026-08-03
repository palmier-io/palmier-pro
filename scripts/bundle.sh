#!/bin/bash
set -euo pipefail

# Usage:
#   scripts/bundle.sh [release|debug]           # ad-hoc signed dev build
#   scripts/bundle.sh debug --fast              # fastest: skip dSYM + deep sign, just env+build
#   scripts/bundle.sh debug --speech             # include bundled speech and MLX
#   scripts/bundle.sh debug --hosted             # include account and hosted AI services
#   scripts/bundle.sh release --intel            # build the Intel local/BYOK edition
#   scripts/bundle.sh release --intel --dmg      # Intel app + PalmierPro-Intel.dmg (no notarization)
#   scripts/bundle.sh debug --all                # include all optional traits
#   scripts/bundle.sh release --sign            # build + Developer ID codesign
#   scripts/bundle.sh release --dist            # build + sign + notarize + staple + DMG

CONFIG="release"
MODE="dev"
INCLUDE_BUNDLED_SPEECH=false
INCLUDE_HOSTED_BACKEND=false
TARGET_ARCH="$(uname -m)"
for arg in "$@"; do
  case "$arg" in
    release|debug) CONFIG="$arg" ;;
    --fast)        MODE="fast" ;;
    --sign)        MODE="sign" ;;
    --dist)        MODE="dist" ;;
    --dmg)         MODE="dmg" ;;
    --speech)      INCLUDE_BUNDLED_SPEECH=true ;;
    --hosted)      INCLUDE_HOSTED_BACKEND=true ;;
    --intel)       TARGET_ARCH="x86_64" ;;
    --all)
      INCLUDE_BUNDLED_SPEECH=true
      INCLUDE_HOSTED_BACKEND=true
      ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

if [ "$CONFIG" = "release" ]; then
  if [ "$TARGET_ARCH" = "arm64" ]; then
    INCLUDE_BUNDLED_SPEECH=true
    INCLUDE_HOSTED_BACKEND=true
  fi
fi

if [ "$TARGET_ARCH" = "x86_64" ] && { $INCLUDE_BUNDLED_SPEECH || $INCLUDE_HOSTED_BACKEND; }; then
  echo "Intel builds do not support --speech or --hosted" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ENV_FILE=".env"
if [ "$CONFIG" = "release" ] && [ -f "$ROOT/.env.prod" ]; then
  ENV_FILE=".env.prod"
fi
if [ -f "$ROOT/$ENV_FILE" ]; then
  echo "==> Loading $ENV_FILE"
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/$ENV_FILE"
  set +a
fi

SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Palmier, Inc. (MMFLRC7562)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-palmier-notary}"
PROVISION_PROFILE="${PROVISION_PROFILE:-$ROOT/scripts/Palmier_Pro_Developer_ID.provisionprofile}"
ENTITLEMENTS="$ROOT/scripts/PalmierPro.entitlements"
KEYCHAIN_ACCESS_GROUP="${KEYCHAIN_ACCESS_GROUP:-MMFLRC7562.io.palmier.pro}"
RESOURCES="$ROOT/Sources/PalmierPro/Resources"
APP="$ROOT/.build/PalmierPro.app"
ZIP="$ROOT/.build/PalmierPro.zip"
if [ "$TARGET_ARCH" = "x86_64" ]; then
  DMG="$ROOT/.build/PalmierPro-Intel.dmg"
  DMG_VOLNAME="PalmierPro Intel"
else
  DMG="$ROOT/.build/PalmierPro.dmg"
  DMG_VOLNAME="PalmierPro"
fi

create_dmg() {
  echo "==> Building DMG ($DMG)"
  rm -f "$DMG"
  local staging
  staging="$(mktemp -d)"
  cp -R "$APP" "$staging/PalmierPro.app"
  ln -s /Applications "$staging/Applications"
  cp "$RESOURCES/AppIcon.icns" "$staging/.VolumeIcon.icns"
  hdiutil create \
    -volname "$DMG_VOLNAME" \
    -srcfolder "$staging" \
    -ov -format UDZO \
    "$DMG"
  rm -rf "$staging"
}

BUILD_ARGS=(-c "$CONFIG")
TRAITS=""
if $INCLUDE_BUNDLED_SPEECH; then
  TRAITS="BundledSpeech"
fi
if $INCLUDE_HOSTED_BACKEND; then
  if [ -n "$TRAITS" ]; then
    TRAITS="$TRAITS,HostedBackend"
  else
    TRAITS="HostedBackend"
  fi
fi
if [ -n "$TRAITS" ]; then
  BUILD_ARGS+=(--traits "$TRAITS")
fi
if [ "$TARGET_ARCH" = "x86_64" ]; then
  BUILD_ARGS+=(--triple x86_64-apple-macosx26.0)
fi

echo "==> Building ($CONFIG, architecture: $TARGET_ARCH, traits: ${TRAITS:-none})"
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/PalmierPro"
SPARKLE_FW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/PalmierPro"
cp "$RESOURCES/Info.plist" "$APP/Contents/Info.plist"

inject_plist() {
  local key="$1" value="$2"
  if [ -z "$value" ]; then
    echo "!! $key not set in $ENV_FILE — app will fatalError on launch" >&2
    return
  fi
  /usr/libexec/PlistBuddy -c "Delete :$key" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :$key string $value" "$APP/Contents/Info.plist"
}

if $INCLUDE_HOSTED_BACKEND; then
  echo "==> Injecting backend config into Info.plist"
  inject_plist PalmierClerkPublishableKey "${CLERK_PUBLISHABLE_KEY:-}"
  inject_plist PalmierConvexDeploymentURL "${CONVEX_DEPLOYMENT_URL:-}"
  inject_plist PalmierConvexHttpURL "${CONVEX_HTTP_URL:-}"
fi
/usr/libexec/PlistBuddy -c "Delete :PalmierBundledSpeech" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :PalmierBundledSpeech bool $INCLUDE_BUNDLED_SPEECH" "$APP/Contents/Info.plist"
cp "$RESOURCES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

# Flatten SwiftPM's resource bundle into the app's Resources tree.
RES_BUNDLE="$(dirname "$BIN")/PalmierPro_PalmierPro.bundle"
if [ -d "$RES_BUNDLE/Fonts" ]; then
  cp -R "$RES_BUNDLE/Fonts" "$APP/Contents/Resources/"
else
  echo "!! missing Fonts/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi

# Ensure the shipped Claude Desktop connector is always up to date with mcpb/ sources.
MCPB_SRC="$ROOT/mcpb"
MCPB_CHECKED_IN="$ROOT/Sources/PalmierPro/Resources/MCPB/palmier-pro.mcpb"
MCPB_FRESH="$(mktemp -d)/palmier-pro.mcpb"
(cd "$MCPB_SRC" && zip -q -X -r "$MCPB_FRESH" manifest.json icon.png server/index.js server/package.json)
if ! unzip -p "$MCPB_CHECKED_IN" server/index.js 2>/dev/null | diff -q - <(unzip -p "$MCPB_FRESH" server/index.js) >/dev/null 2>&1 \
  || ! unzip -p "$MCPB_CHECKED_IN" manifest.json 2>/dev/null | diff -q - <(unzip -p "$MCPB_FRESH" manifest.json) >/dev/null 2>&1; then
  echo "==> refreshing checked-in palmier-pro.mcpb from mcpb/ sources"
  cp "$MCPB_FRESH" "$MCPB_CHECKED_IN"
fi
cp "$MCPB_FRESH" "$APP/Contents/Resources/palmier-pro.mcpb"
rm -rf "$(dirname "$MCPB_FRESH")"
if [ -d "$RES_BUNDLE/Images" ]; then
  cp -R "$RES_BUNDLE/Images" "$APP/Contents/Resources/"
fi
# .lproj folders must live at the bundle root for macOS to resolve them.
LOCALIZATION_COUNT=0
for locale_dir in "$RES_BUNDLE"/*.lproj; do
  [ -d "$locale_dir" ] || continue
  for strings_file in Localizable.strings InfoPlist.strings; do
    if [ ! -f "$locale_dir/$strings_file" ]; then
      echo "!! missing $strings_file in $locale_dir" >&2
      exit 1
    fi
  done
  cp -R "$locale_dir" "$APP/Contents/Resources/"
  LOCALIZATION_COUNT=$((LOCALIZATION_COUNT + 1))
done
if [ "$LOCALIZATION_COUNT" -eq 0 ]; then
  echo "!! no compiled localizations in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi
if [ -d "$RES_BUNDLE/Changelog" ]; then
  cp -R "$RES_BUNDLE/Changelog" "$APP/Contents/Resources/"
else
  echo "!! missing Changelog/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi
if [ -d "$RES_BUNDLE/Models" ]; then
  cp -R "$RES_BUNDLE/Models" "$APP/Contents/Resources/"
else
  echo "!! missing Models/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi

if ! ls "$RES_BUNDLE"/*.metallib >/dev/null 2>&1; then
  echo "!! no .metallib in SwiftPM resource bundle at $RES_BUNDLE — Metal effects would be missing" >&2
  exit 1
fi
cp "$RES_BUNDLE"/*.metallib "$APP/Contents/Resources/"

if $INCLUDE_BUNDLED_SPEECH; then
  MLX_METALLIB="$ROOT/.build/$CONFIG/mlx.metallib"
  if [ ! -f "$MLX_METALLIB" ]; then
    echo "==> Building MLX metallib ($CONFIG)"
    BUILD_DIR="$ROOT/.build" "$ROOT/.build/checkouts/speech-swift/scripts/build_mlx_metallib.sh" "$CONFIG"
  fi
  if [ ! -f "$MLX_METALLIB" ]; then
    echo "!! missing $MLX_METALLIB — on-device speech features (VAD, speaker ID) would die silently" >&2
    exit 1
  fi
  mkdir -p "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
  cp "$MLX_METALLIB" "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"
fi

install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/PalmierPro"
touch "$APP"

if [ "$MODE" = "fast" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -F "$SIGNING_IDENTITY" >/dev/null; then
    echo "==> Codesigning main app with $SIGNING_IDENTITY (no timestamp, no helpers)"
    codesign --force --sign "$SIGNING_IDENTITY" "$APP"
  else
    echo "==> $SIGNING_IDENTITY not found — ad-hoc signing (Keychain ACLs reset each rebuild)"
    codesign --force --deep --sign - "$APP"
  fi
  codesign --verify --strict --verbose=2 "$APP"
  echo "==> Done: $APP (fast mode — no dSYM)"
  exit 0
fi

DSYM="$ROOT/.build/PalmierPro.dSYM"
echo "==> Generating dSYM"
rm -rf "$DSYM"
dsymutil "$APP/Contents/MacOS/PalmierPro" -o "$DSYM"

if [ "$MODE" = "dev" ]; then
  echo "==> Ad-hoc signing dev app"
  codesign --force --deep --sign - "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  echo "==> Done: $APP (ad-hoc signed)"
  exit 0
fi

if [ "$MODE" = "dmg" ]; then
  echo "==> Ad-hoc signing app for DMG packaging"
  codesign --force --deep --sign - "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  create_dmg
  echo "==> Done: $DMG"
  exit 0
fi

echo "==> Codesigning nested Sparkle helpers"
SPARKLE_CURRENT="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
for helper in \
    "$SPARKLE_CURRENT/Autoupdate" \
    "$SPARKLE_CURRENT/Updater.app/Contents/MacOS/Updater" \
    "$SPARKLE_CURRENT/Updater.app" \
    "$SPARKLE_CURRENT/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "$SPARKLE_CURRENT/XPCServices/Downloader.xpc" \
    "$SPARKLE_CURRENT/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
    "$SPARKLE_CURRENT/XPCServices/Installer.xpc"; do
  [ -e "$helper" ] && codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$helper"
done

echo "==> Codesigning Sparkle framework"
codesign --force --options runtime --timestamp \
  --sign "$SIGNING_IDENTITY" \
  "$APP/Contents/Frameworks/Sparkle.framework"

echo "==> Codesigning main app"
if $INCLUDE_HOSTED_BACKEND; then
  echo "==> Embedding hosted-service provisioning profile"
  if [ ! -f "$PROVISION_PROFILE" ]; then
    echo "!! provisioning profile not found at $PROVISION_PROFILE" >&2
    exit 1
  fi
  cp "$PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"
  inject_plist PalmierClerkKeychainAccessGroup "$KEYCHAIN_ACCESS_GROUP"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" \
    "$APP"
else
  codesign --force --options runtime --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$APP"
fi
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

create_dmg

echo "==> Codesigning DMG"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"

echo "==> Submitting DMG to notary"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Stapling DMG"
xcrun stapler staple "$DMG"

echo "==> Signing DMG with Sparkle EdDSA key"
SPARKLE_SIG="$("$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update" "$DMG")"

echo ""
echo "==> Done"
echo "   App: $APP"
echo "   DMG: $DMG"
echo ""
echo "Sparkle signature for appcast entry:"
echo "  $SPARKLE_SIG"
echo ""
echo "Add an <item> to appcast.xml with:"
echo "  - version, shortVersionString from Info.plist"
echo "  - url pointing at the GitHub Release download"
echo "  - length=$(stat -f%z "$DMG")"
echo "  - the sparkle:edSignature from above"
