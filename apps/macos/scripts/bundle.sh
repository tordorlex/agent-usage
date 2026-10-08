#!/usr/bin/env bash
#
# Assembles Meter.app: the SwiftUI client plus a self-contained copy of the
# Node statistics engine, so the bundle runs with nothing installed.
#
# Layout produced:
#   Meter.app/Contents/MacOS/Meter                the SwiftUI executable
#   Meter.app/Contents/Resources/JusageEngine/    deployed engine
#     ├── dist/index.js                             entry the locator spawns
#     ├── node_modules/                             hono / fzstd / core, resolved
#     └── node                                      bundled Node runtime
#   Meter.app/Contents/Resources/AppIcon.icns
#
# Usage:
#   apps/macos/scripts/bundle.sh [--skip-node] [--configuration release|debug]
#
# Env:
#   JUSAGE_NODE_BIN   Node runtime to embed (default: `command -v node`)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MACOS_DIR/../.." && pwd)"

CONFIGURATION="release"
SKIP_NODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-node) SKIP_NODE=1; shift ;;
    --configuration) CONFIGURATION="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

APP_NAME="Meter"
DISPLAY_NAME="Meter"
BUNDLE_ID="com.juejin.jusage.mac"

# The repo root has no version field, so read the published product version and
# reject anything that does not look like one (e.g. the literal "undefined").
read_version() {
  node -p "const v = require('$1').version; /^[0-9]+\\.[0-9]+\\.[0-9]+/.test(v) ? v : ''" 2>/dev/null
}
VERSION="$(read_version "$REPO_ROOT/packages/cli/package.json")"
[[ -z "$VERSION" ]] && VERSION="$(read_version "$REPO_ROOT/packages/engine/package.json")"
[[ -z "$VERSION" ]] && VERSION="0.1.0"

APP_DIR="$MACOS_DIR/dist/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
RESOURCES="$CONTENTS/Resources"
ENGINE_DIR="$RESOURCES/JusageEngine"

# SwiftPM/Clang caches, kept inside the repo so builds work in sandboxes that
# forbid writing to ~/Library.
SCRATCH="$MACOS_DIR/.build"
CACHE_ARGS=(
  --scratch-path "$SCRATCH"
  --cache-path "$MACOS_DIR/.swiftpm/cache"
  --config-path "$MACOS_DIR/.swiftpm/config"
  --security-path "$MACOS_DIR/.swiftpm/security"
  --disable-sandbox
)

# Step 1 compiles TypeScript through the workspace's devDependencies. If those
# are missing (a previous install ran with --production) the failure surfaces as
# a bare "tsc: command not found"; say what to do instead.
if [[ ! -x "$REPO_ROOT/node_modules/.bin/tsc" ]]; then
  echo "error: node_modules/.bin/tsc is missing — run 'pnpm install' at the repo root" >&2
  exit 1
fi

echo "==> 1/5 Building the statistics engine (TypeScript)"
cd "$REPO_ROOT"
npm_config_manage_package_manager_versions=false \
  pnpm --filter @juejin-opensource/jusage-engine build

echo "==> 2/5 Deploying the engine with its runtime dependencies"
STAGING="$MACOS_DIR/.build/engine-deploy"
rm -rf "$STAGING"
npm_config_manage_package_manager_versions=false \
  pnpm --filter @juejin-opensource/jusage-engine deploy "$STAGING" \
  --prod --legacy --store-dir "$REPO_ROOT/.pnpm-store" >/dev/null

echo "==> 3/5 Building the SwiftUI client ($CONFIGURATION)"
cd "$MACOS_DIR"
CLANG_MODULE_CACHE_PATH="$MACOS_DIR/.clang-cache" \
  swift build -c "$CONFIGURATION" "${CACHE_ARGS[@]}"
BINARY="$(CLANG_MODULE_CACHE_PATH="$MACOS_DIR/.clang-cache" swift build -c "$CONFIGURATION" "${CACHE_ARGS[@]}" --show-bin-path)/$APP_NAME"

echo "==> 4/5 Assembling $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$ENGINE_DIR"
cp "$BINARY" "$CONTENTS/MacOS/$APP_NAME"

# The deployed tree keeps relative symlinks into its own .pnpm store, so a
# recursive copy stays self-contained.
cp -R "$STAGING/." "$ENGINE_DIR/"

# pnpm also drops a self-reference into .pnpm/node_modules (@juejin-opensource/
# jusage-engine -> ../../../../../packages/engine). Nothing in the bundle imports
# it and it dangles outside the repo, which makes `codesign --verify --deep` fail
# with "No such file or directory" — prune every symlink whose target is gone.
PRUNED=0
while IFS= read -r -d '' link; do
  rm -f "$link"
  PRUNED=$((PRUNED + 1))
done < <(find "$ENGINE_DIR" -type l ! -exec test -e {} \; -print0)
[[ "$PRUNED" -gt 0 ]] && echo "    pruned $PRUNED dangling symlink(s) from the engine tree"

if [[ "$SKIP_NODE" -eq 0 ]]; then
  NODE_BIN="${JUSAGE_NODE_BIN:-$(command -v node || true)}"
  if [[ -z "$NODE_BIN" ]]; then
    echo "error: no node runtime found; set JUSAGE_NODE_BIN or pass --skip-node" >&2
    exit 1
  fi
  cp "$NODE_BIN" "$ENGINE_DIR/node"
  chmod +x "$ENGINE_DIR/node"
  echo "    embedded node: $NODE_BIN ($("$NODE_BIN" --version))"
else
  echo "    --skip-node: the app will fall back to a node on PATH"
fi

# App icon: the macOS app ships its own background-less mark
# (apps/macos/resources/icon.png); fall back to the Electron app's PNG when the
# local one is missing.
ICON_PNG="$MACOS_DIR/resources/icon.png"
[[ -f "$ICON_PNG" ]] || ICON_PNG="$REPO_ROOT/apps/desktop/resources/icon.png"
if [[ -f "$ICON_PNG" ]]; then
  ICONSET="$MACOS_DIR/.build/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1 || true
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1 || true
  done
  if iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns" >/dev/null 2>&1; then
    echo "    icon: AppIcon.icns"
  fi
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <!-- Languages the app renders in. Declaring them is what makes macOS offer
       the per-app language picker, and that choice lands in
       Locale.preferredLanguages — which is exactly where Meter reads it. -->
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
  </array>
  <!-- Menu-bar-only app: accessory activation policy, no Dock icon. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

echo "==> 5/5 Signing (ad-hoc)"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 \
  && echo "    signed ad-hoc" \
  || echo "    warning: ad-hoc signing failed; Gatekeeper may complain on first launch"

echo
echo "Built: $APP_DIR"
du -sh "$APP_DIR" | awk '{print "Size:  " $1}'
