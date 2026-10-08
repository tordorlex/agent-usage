#!/usr/bin/env bash
#
# Packages the assembled Meter.app into a distributable .dmg.
#
# The image contains the app plus an /Applications symlink, so the usual
# drag-and-drop install works when the user opens it.
#
# Layout produced:
#   apps/macos/dist/Meter-<version>.dmg       compressed read-only image
#
# Usage:
#   apps/macos/scripts/dmg.sh [--skip-build]
#
# Env:
#   JUSAGE_DMG_VOLNAME   Mounted volume name (default: Meter <version>)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="Meter"
SKIP_BUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

APP_DIR="$MACOS_DIR/dist/$APP_NAME.app"
DIST_DIR="$MACOS_DIR/dist"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  echo "==> 1/4 Assembling $APP_NAME.app"
  bash "$SCRIPT_DIR/bundle.sh"
else
  echo "==> 1/4 --skip-build: reusing $APP_DIR"
fi

if [[ ! -d "$APP_DIR" ]]; then
  echo "error: $APP_DIR not found; run without --skip-build first" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)"
[[ -z "$VERSION" ]] && VERSION="0.1.0"
OUTPUT="$DIST_DIR/$APP_NAME-$VERSION.dmg"
VOLNAME="${JUSAGE_DMG_VOLNAME:-Meter $VERSION}"

echo "==> 2/4 Staging the disk image contents"
STAGING="$MACOS_DIR/.build/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
# ditto keeps the engine's relative symlinks and extended attributes intact.
ditto "$APP_DIR" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

echo "==> 3/4 Creating $OUTPUT"
rm -f "$OUTPUT"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$OUTPUT" >/dev/null

echo "==> 4/4 Verifying"
hdiutil verify "$OUTPUT" >/dev/null && echo "    checksum OK" || echo "    warning: hdiutil verify failed"

echo
echo "Built: $OUTPUT"
du -sh "$OUTPUT" | awk '{print "Size:  " $1}'
