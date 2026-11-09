#!/bin/bash
set -euo pipefail

# Usage:
#   scripts/bundle.sh [release|debug]           # ad-hoc signed dev build
#   scripts/bundle.sh debug --fast              # fastest: skip dSYM + deep sign, just env+build
#   scripts/bundle.sh debug --speech             # include bundled speech and MLX
#   scripts/bundle.sh debug --all                # include all optional traits
#   scripts/bundle.sh release --sign            # build + Developer ID codesign
#   scripts/bundle.sh release --dist            # build + sign + notarize + staple + DMG

CONFIG="release"
MODE="dev"
ENABLE_ALL_TRAITS=false
INCLUDE_BUNDLED_SPEECH=false
for arg in "$@"; do
  case "$arg" in
    release|debug) CONFIG="$arg" ;;
    --fast)        MODE="fast" ;;
    --sign)        MODE="sign" ;;
    --dist)        MODE="dist" ;;
    --speech)      INCLUDE_BUNDLED_SPEECH=true ;;
    --all)
      ENABLE_ALL_TRAITS=true
      INCLUDE_BUNDLED_SPEECH=true
      ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

if [ "$CONFIG" = "release" ]; then
  ENABLE_ALL_TRAITS=true
  INCLUDE_BUNDLED_SPEECH=true
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

if [ -z "${SIGNING_IDENTITY:-}" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -qF "Developer ID Application: Compositor Pro"; then
    SIGNING_IDENTITY="Developer ID Application: Compositor Pro (MMFLRC7562)"
  else
    SIGNING_IDENTITY="Developer ID Application: Palmier, Inc. (MMFLRC7562)"
  fi
fi

# A machine without the release identity in its keychain cannot sign with it, and
# install_name_tool has already invalidated whatever signature the build produced. Leaving the
# bundle in that state makes dyld kill it on launch (SIGKILL / Code Signature Invalid), which
# looks exactly like an instant crash. Fall back to an ad-hoc signature, which is enough to run
# locally; only release builds actually need Developer ID.
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGNING_IDENTITY"; then
  if [ "$CONFIG" = "release" ]; then
    echo "!! $SIGNING_IDENTITY not found in the keychain." >&2
    echo "!! Pass SIGNING_IDENTITY=<identity>, or put the certificate in the keychain." >&2
    exit 1
  fi
  echo "==> $SIGNING_IDENTITY not in the keychain — signing ad-hoc so the app can still launch" >&2
  SIGNING_IDENTITY="-"
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-compositor-notary}"
PROVISION_PROFILE="${PROVISION_PROFILE:-$ROOT/scripts/Compositor_Pro_Developer_ID.provisionprofile}"
# Fallback to legacy filename if present
if [ ! -f "$PROVISION_PROFILE" ] && [ -f "$ROOT/scripts/Palmier_Pro_Developer_ID.provisionprofile" ]; then
  PROVISION_PROFILE="$ROOT/scripts/Palmier_Pro_Developer_ID.provisionprofile"
fi
ENTITLEMENTS="$ROOT/scripts/CompositorPro.entitlements"
KEYCHAIN_ACCESS_GROUP="${KEYCHAIN_ACCESS_GROUP:-MMFLRC7562.io.compositor.pro}"
RESOURCES="$ROOT/Sources/CompositorPro/Resources"
APP="$ROOT/.build/CompositorPro.app"
ZIP="$ROOT/.build/CompositorPro.zip"
DMG="$ROOT/.build/CompositorPro.dmg"

BUILD_ARGS=(-c "$CONFIG")
if $ENABLE_ALL_TRAITS; then
  TRAITS="all"
  BUILD_ARGS+=(--enable-all-traits)
else
  TRAITS=""
  if $INCLUDE_BUNDLED_SPEECH; then
    TRAITS="BundledSpeech"
  fi
  if [ -n "$TRAITS" ]; then
    BUILD_ARGS+=(--traits "$TRAITS")
  fi
fi

echo "==> Building ($CONFIG, traits: ${TRAITS:-none})"
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/CompositorPro"
SPARKLE_FW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/CompositorPro"
cp "$RESOURCES/Info.plist" "$APP/Contents/Info.plist"

# Local-only build: no Sentry/PostHog config and no backend keys are injected.
# Stale keys from older builds are stripped so nothing can leak into the bundle.
for _stale_key in SentryDSN PostHogProjectToken PostHogHost CompositorClerkPublishableKey CompositorConvexDeploymentURL CompositorConvexHttpURL; do
  /usr/libexec/PlistBuddy -c "Delete :$_stale_key" "$APP/Contents/Info.plist" 2>/dev/null || true
done
cp "$RESOURCES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

# Flatten SwiftPM's resource bundle into the app's Resources tree.
RES_BUNDLE="$(dirname "$BIN")/CompositorPro_CompositorPro.bundle"
# Newer SwiftPM emits macOS-style bundles that nest payloads under Contents/Resources.
if [ -d "$RES_BUNDLE/Contents/Resources" ]; then
  RES_BUNDLE="$RES_BUNDLE/Contents/Resources"
fi
if [ -d "$RES_BUNDLE/Fonts" ]; then
  cp -R "$RES_BUNDLE/Fonts" "$APP/Contents/Resources/"
else
  echo "!! missing Fonts/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi

# Ensure the shipped Claude Desktop connector is always up to date with mcpb/ sources.
MCPB_SRC="$ROOT/mcpb"
MCPB_CHECKED_IN="$ROOT/Sources/CompositorPro/Resources/MCPB/compositor-pro.mcpb"
MCPB_FRESH="$(mktemp -d)/compositor-pro.mcpb"
(cd "$MCPB_SRC" && zip -q -X -r "$MCPB_FRESH" manifest.json icon.png server/index.js server/package.json)
if ! unzip -p "$MCPB_CHECKED_IN" server/index.js 2>/dev/null | diff -q - <(unzip -p "$MCPB_FRESH" server/index.js) >/dev/null 2>&1 \
  || ! unzip -p "$MCPB_CHECKED_IN" manifest.json 2>/dev/null | diff -q - <(unzip -p "$MCPB_FRESH" manifest.json) >/dev/null 2>&1; then
  echo "==> refreshing checked-in compositor-pro.mcpb from mcpb/ sources"
  cp "$MCPB_FRESH" "$MCPB_CHECKED_IN"
fi
cp "$MCPB_FRESH" "$APP/Contents/Resources/compositor-pro.mcpb"
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

install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/CompositorPro"
touch "$APP"

if [ "$MODE" = "fast" ]; then
  echo "==> Codesigning main app with $SIGNING_IDENTITY (no timestamp, no helpers)"
  codesign --force --sign "$SIGNING_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  echo "==> Done: $APP (fast mode — stable identity, no dSYM)"
  exit 0
fi

DSYM="$ROOT/.build/CompositorPro.dSYM"
echo "==> Generating dSYM"
rm -rf "$DSYM"
dsymutil "$APP/Contents/MacOS/CompositorPro" -o "$DSYM"

upload_dsyms() {
  if [ -z "${SENTRY_AUTH_TOKEN:-}" ] || [ -z "${SENTRY_ORG:-}" ] || [ -z "${SENTRY_PROJECT:-}" ]; then
    echo "==> Sentry creds not set — skipping dSYM upload"
    return
  fi
  if ! command -v sentry-cli >/dev/null 2>&1; then
    echo "!! sentry-cli not found in PATH — skipping dSYM upload"
    return
  fi
  echo "==> Uploading dSYM to Sentry"
  sentry-cli debug-files upload --include-sources "$DSYM" || echo "!! sentry-cli upload failed (continuing)"
}

if [ "$MODE" = "dev" ]; then
  echo "==> Ad-hoc signing dev app"
  # Sign nested code first, then the bundle. `--deep` alone is unreliable for a large
  # binary: it left the app half-signed and dyld killed it with "Code Signature Invalid".
  if [ -d "$APP/Contents/Frameworks" ]; then
    find "$APP/Contents/Frameworks" -maxdepth 2 -name "*.dylib" -print0 2>/dev/null \
      | xargs -0 -r codesign --force --sign -
    find "$APP/Contents/Frameworks" -maxdepth 1 -name "*.framework" -print0 2>/dev/null \
      | xargs -0 -r codesign --force --sign -
  fi
  codesign --force --sign - "$APP/Contents/MacOS/CompositorPro"
  codesign --force --sign - "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  upload_dsyms
  echo "==> Done: $APP (ad-hoc signed)"
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

echo "==> Embedding provisioning profile + keychain access group"
if [ ! -f "$PROVISION_PROFILE" ]; then
  echo "!! provisioning profile not found at $PROVISION_PROFILE" >&2
  exit 1
fi
cp "$PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"
inject_plist CompositorClerkKeychainAccessGroup "$KEYCHAIN_ACCESS_GROUP"

echo "==> Codesigning main app"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
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
cp -R "$APP" "$STAGING/CompositorPro.app"
ln -s /Applications "$STAGING/Applications"
cp "$RESOURCES/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
hdiutil create \
  -volname "CompositorPro" \
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

upload_dsyms

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
