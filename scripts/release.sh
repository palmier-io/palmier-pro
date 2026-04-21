#!/bin/bash
set -euo pipefail

# Usage: scripts/release.sh <version>       e.g. scripts/release.sh 0.1.3
#
# Full release pipeline:
#   1. Preflight (on main, tree clean, tag free, in sync with origin)
#   2. Bump CFBundleShortVersionString + auto-increment CFBundleVersion
#   3. Prompt for release notes in $EDITOR (prefilled with recent commits)
#   4. Run bundle.sh release --dist
#   5. Commit + push version bump
#   6. Tag + push tag
#   7. gh release create with the DMG and notes
#   8. Update appcast.xml + commit + push
#
# Bails out before anything public-visible if a preflight check fails.

if [ $# -ne 1 ]; then
  echo "usage: $0 <version>  (e.g. 0.1.3)" >&2
  exit 1
fi

VERSION="$1"
TAG="v$VERSION"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must be X.Y.Z (got: $VERSION)" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Sources/PalmierPro/Resources/Info.plist"
APPCAST="$ROOT/appcast.xml"
DMG="$ROOT/.build/PalmierPro.dmg"
cd "$ROOT"

echo "==> Preflight"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
  echo "error: must be on main (got: $BRANCH)" >&2
  exit 1
fi

if ! git diff-index --quiet HEAD --; then
  echo "error: working tree has uncommitted changes:" >&2
  git status --short >&2
  exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists locally" >&2
  exit 1
fi

git fetch origin main --quiet
git fetch origin --tags --quiet
if git rev-parse "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists on origin" >&2
  exit 1
fi
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "error: local main differs from origin/main. Push or pull first." >&2
  exit 1
fi

echo "==> Generating release notes from commit log"
NOTES_CLEAN="$(mktemp -t palmier-release.XXXXXX).md"
trap 'rm -f "$NOTES_CLEAN"' EXIT
LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo '')"
{
  echo "## What's new"
  echo ""
  if [ -n "$LAST_TAG" ]; then
    git log --pretty=format:"- %s" "$LAST_TAG..HEAD"
    echo ""
  else
    echo "First release."
  fi
} >"$NOTES_CLEAN"
echo "    (edit on GitHub later if you want to polish)"

echo "==> Bumping version"
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")"
NEW_BUILD=$((CURRENT_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
echo "    $VERSION (build $NEW_BUILD)"

echo "==> Building signed + notarized DMG"
BUILD_LOG="$(mktemp -t palmier-build.XXXXXX).log"
trap 'rm -f "$NOTES_CLEAN" "$BUILD_LOG"' EXIT
./scripts/bundle.sh release --dist 2>&1 | tee "$BUILD_LOG"

SIG_LINE="$(grep 'sparkle:edSignature' "$BUILD_LOG" | tail -1)"
SIGNATURE="$(echo "$SIG_LINE" | sed -E 's/.*edSignature="([^"]+)".*/\1/')"
LENGTH="$(echo "$SIG_LINE" | sed -E 's/.*length="([^"]+)".*/\1/')"
if [ -z "$SIGNATURE" ] || [ -z "$LENGTH" ]; then
  echo "error: couldn't extract Sparkle signature or length from build output" >&2
  exit 1
fi

echo "==> Committing + pushing version bump"
git add "$PLIST"
git commit -m "Bump to $VERSION"
git push origin main

echo "==> Tagging $TAG"
git tag "$TAG"
git push origin "$TAG"

echo "==> Creating GH release"
gh release create "$TAG" "$DMG" --title "$TAG" --notes-file "$NOTES_CLEAN"

echo "==> Updating appcast.xml"
PUBDATE="$(date -R)"
export VERSION NEW_BUILD PUBDATE LENGTH SIGNATURE
python3 <<'PYEOF'
import os
v = os.environ["VERSION"]
b = os.environ["NEW_BUILD"]
d = os.environ["PUBDATE"]
l = os.environ["LENGTH"]
s = os.environ["SIGNATURE"]
url = f"https://github.com/palmier-io/palmier-pro/releases/download/v{v}/PalmierPro.dmg"

item = f"""        <item>
            <title>Version {v}</title>
            <pubDate>{d}</pubDate>
            <sparkle:version>{b}</sparkle:version>
            <sparkle:shortVersionString>{v}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
            <enclosure
                url="{url}"
                length="{l}"
                type="application/octet-stream"
                sparkle:edSignature="{s}"/>
        </item>"""

path = "appcast.xml"
with open(path) as f:
    content = f.read()
content = content.replace("    </channel>", item + "\n    </channel>")
with open(path, "w") as f:
    f.write(content)
PYEOF

git add "$APPCAST"
git commit -m "Add $TAG to appcast"
git push origin main

echo ""
echo "==> Released $TAG"
echo "    https://github.com/palmier-io/palmier-pro/releases/tag/$TAG"
