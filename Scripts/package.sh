#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex Monitor"
source "$ROOT/Scripts/version.sh"
APP_BUNDLE_IDENTIFIER="${APP_BUNDLE_IDENTIFIER:-com.example.codexmonitor}"
APP_GROUP_IDENTIFIER="${APP_GROUP_IDENTIFIER:-group.com.example.codexmonitor}"
WIDGET_BUNDLE_IDENTIFIER="${WIDGET_BUNDLE_IDENTIFIER:-com.example.codexmonitor.widget}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
DERIVED_DATA="$ROOT/.build/xcode"
APP_SOURCE="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
APP_DIR="$ROOT/dist/$APP_NAME.app"
WIDGET_DIR="$APP_DIR/Contents/PlugIns/CodexMonitorWidget.appex"
ICON_PATH="$APP_DIR/Contents/Resources/AppIcon.icns"
APP_EXECUTABLE="$APP_DIR/Contents/MacOS/$APP_NAME"
WIDGET_EXECUTABLE="$WIDGET_DIR/Contents/MacOS/CodexMonitorWidget"
BADGE_RESOURCES="$ROOT/Resources/CodexUsageBadge"
PINNED_BADGE_SHA256="d6e1b2d1cff2ef63964fe7b31797357d0ff25c397bdb66de351c87b1a48541db"

cd "$ROOT"

# Use a full Xcode SDK without changing the machine's xcode-select setting.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  printf '%s\n' \
    "Packaging the app and WidgetKit extension requires a full Xcode installation." \
    "Select it with: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" \
    >&2
  exit 1
fi

"$ROOT/Scripts/generate-project.sh"

python3 "$ROOT/Scripts/verify_badge_bundle.py"

CHATGPT_NODE="${CODEX_BADGE_NODE:-/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node}"
if [[ ! -x "$CHATGPT_NODE" ]]; then
  CHATGPT_NODE="$(command -v node || true)"
fi
if [[ -z "$CHATGPT_NODE" ]]; then
  printf '%s\n' 'Node.js is required to validate the bundled Badge scripts.' >&2
  exit 1
fi
while IFS= read -r -d '' script; do
  "$CHATGPT_NODE" --check "$script"
done < <(find "$BADGE_RESOURCES" -type f -name '*.cjs' -print0)

mkdir -p "$ROOT/dist"
if [[ -d "$APP_DIR" ]]; then
  BACKUP_ARCHIVE="$ROOT/dist/backups/$(date +%Y%m%d-%H%M%S)/Codex Monitor-before-package.zip"
  mkdir -p "$(dirname "$BACKUP_ARCHIVE")"
  ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$BACKUP_ARCHIVE"
  unzip -tqq "$BACKUP_ARCHIVE"
fi
rm -rf "$APP_DIR"

xcodebuild \
  -quiet \
  -project "$ROOT/CodexUsageBar.xcodeproj" \
  -scheme CodexUsageBar \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  APP_BUNDLE_IDENTIFIER="$APP_BUNDLE_IDENTIFIER" \
  APP_GROUP_IDENTIFIER="$APP_GROUP_IDENTIFIER" \
  WIDGET_BUNDLE_IDENTIFIER="$WIDGET_BUNDLE_IDENTIFIER" \
  ARCHS="${BUILD_ARCHS:-arm64 x86_64}" \
  ONLY_ACTIVE_ARCH=NO \
  build

ditto "$APP_SOURCE" "$APP_DIR"

mkdir -p "$APP_DIR/Contents/Resources"
# Remove a stale PNG left by incremental Xcode builds; ICNS is the app icon.
rm -f "$APP_DIR/Contents/Resources/AppIcon-1024.png"
python3 "$ROOT/Scripts/verify_badge_bundle.py" --stage "$APP_DIR/Contents/Resources/CodexUsageBadge"
ACTUAL_BADGE_SHA256="$(shasum -a 256 "$APP_DIR/Contents/Resources/CodexUsageBadge/agent.cjs" | awk '{print $1}')"
if [[ "$ACTUAL_BADGE_SHA256" != "$PINNED_BADGE_SHA256" ]]; then
  printf 'Packaged Badge build hash mismatch: %s\n' "$ACTUAL_BADGE_SHA256" >&2
  exit 1
fi

# Optional local artwork is not part of the public source distribution.
if [[ "${INCLUDE_LOCAL_MENU_ICON:-0}" == "1" && -f "$ROOT/Resources/OfficialCodexMenuTemplate.png" ]]; then
  cp "$ROOT/Resources/OfficialCodexMenuTemplate.png" "$APP_DIR/Contents/Resources/"
fi

# Local development builds can inherit provenance/quarantine metadata while
# being copied between build and install locations. That metadata makes
# LaunchServices re-evaluate an otherwise valid stable signature after reboot.
xattr -cr "$APP_DIR"

if [[ ! -d "$WIDGET_DIR" ]]; then
  printf 'Missing embedded WidgetKit extension: %s\n' "$WIDGET_DIR" >&2
  exit 1
fi
if [[ ! -f "$ICON_PATH" ]]; then
  printf 'Missing application icon: %s\n' "$ICON_PATH" >&2
  exit 1
fi
if [[ ! -f "$APP_EXECUTABLE" || ! -f "$WIDGET_EXECUTABLE" ]]; then
  printf '%s\n' "Missing executable in the packaged app or widget." >&2
  exit 1
fi

# Xcode release products can retain DWARF paths that disclose the build machine's
# local username and checkout path. Remove debug symbols before distribution.
strip -S "$APP_EXECUTABLE"
strip -S "$WIDGET_EXECUTABLE"

TEMPORARY_ENTITLEMENTS="$(mktemp -d)"
trap 'rm -rf "$TEMPORARY_ENTITLEMENTS"' EXIT

cp \
  "$ROOT/Resources/CodexUsageBar.entitlements" \
  "$TEMPORARY_ENTITLEMENTS/app.entitlements"
cp \
  "$ROOT/Resources/CodexUsageWidget.entitlements" \
  "$TEMPORARY_ENTITLEMENTS/widget.entitlements"

/usr/libexec/PlistBuddy \
  -c "Set :com.apple.security.application-groups:0 $APP_GROUP_IDENTIFIER" \
  "$TEMPORARY_ENTITLEMENTS/app.entitlements"
/usr/libexec/PlistBuddy \
  -c "Set :com.apple.security.application-groups:0 $APP_GROUP_IDENTIFIER" \
  "$TEMPORARY_ENTITLEMENTS/widget.entitlements"

SIGN_ARGUMENTS=(--force --sign "$CODE_SIGN_IDENTITY")
if [[ "$CODE_SIGN_IDENTITY" != "-" ]]; then
  SIGN_ARGUMENTS+=(--options runtime --timestamp)
fi

codesign \
  "${SIGN_ARGUMENTS[@]}" \
  --entitlements "$TEMPORARY_ENTITLEMENTS/widget.entitlements" \
  "$WIDGET_DIR"
codesign \
  "${SIGN_ARGUMENTS[@]}" \
  --entitlements "$TEMPORARY_ENTITLEMENTS/app.entitlements" \
  "$APP_DIR"

plutil -lint "$APP_DIR/Contents/Info.plist"
plutil -lint "$WIDGET_DIR/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

printf 'Packaged: %s\n' "$APP_DIR"
printf 'Version: %s (%s)\n' "$VERSION" "$BUILD_NUMBER"
if [[ "${SHOW_BUNDLE_IDENTIFIERS:-0}" == "1" ]]; then
  printf 'App bundle: %s\n' "$APP_BUNDLE_IDENTIFIER"
  printf 'Widget bundle: %s\n' "$WIDGET_BUNDLE_IDENTIFIER"
  printf 'App Group: %s\n' "$APP_GROUP_IDENTIFIER"
fi
