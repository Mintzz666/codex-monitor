#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex Monitor"
VERSION="${VERSION:-1.4.1}"
BUILD_NUMBER="${BUILD_NUMBER:-30}"
APP_GROUP_IDENTIFIER="${APP_GROUP_IDENTIFIER:-group.com.example.codexmonitor}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
DERIVED_DATA="$ROOT/.build/xcode"
APP_SOURCE="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
APP_DIR="$ROOT/dist/$APP_NAME.app"
WIDGET_DIR="$APP_DIR/Contents/PlugIns/CodexMonitorWidget.appex"
ICON_PATH="$APP_DIR/Contents/Resources/AppIcon.icns"
APP_EXECUTABLE="$APP_DIR/Contents/MacOS/$APP_NAME"
WIDGET_EXECUTABLE="$WIDGET_DIR/Contents/MacOS/CodexMonitorWidget"

cd "$ROOT"

if ! xcodebuild -version >/dev/null 2>&1; then
  printf '%s\n' \
    "Packaging the app and WidgetKit extension requires a full Xcode installation." \
    "Select it with: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" \
    >&2
  exit 1
fi

"$ROOT/Scripts/generate-project.sh"

rm -rf "$DERIVED_DATA" "$APP_DIR"
mkdir -p "$ROOT/dist"

xcodebuild \
  -project "$ROOT/CodexUsageBar.xcodeproj" \
  -scheme CodexUsageBar \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  APP_GROUP_IDENTIFIER="$APP_GROUP_IDENTIFIER" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  build

ditto "$APP_SOURCE" "$APP_DIR"

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
printf 'App Group: %s\n' "$APP_GROUP_IDENTIFIER"
