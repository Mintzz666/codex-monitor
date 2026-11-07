#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/Scripts/version.sh"
INSTALL_DIRECTORY="${INSTALL_DIRECTORY:-/Applications}"
INSTALLED_APP="$INSTALL_DIRECTORY/Codex Monitor.app"
BUILT_APP="${BUILT_APP_PATH:-$ROOT/dist/Codex Monitor.app}"
BACKUP_ARCHIVE="${INSTALL_BACKUP_DIRECTORY:-$ROOT/dist/backups}/$(date +%Y%m%d-%H%M%S)-$$/Codex Monitor.zip"

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }
if [[ -d "$INSTALLED_APP" ]]; then
  APP_BUNDLE_IDENTIFIER="$(plist_value "$INSTALLED_APP/Contents/Info.plist" CFBundleIdentifier)"
  APP_GROUP_IDENTIFIER="$(plist_value "$INSTALLED_APP/Contents/Info.plist" CodexUsageAppGroupIdentifier)"
  WIDGET_BUNDLE_IDENTIFIER="$(plist_value "$INSTALLED_APP/Contents/PlugIns/CodexMonitorWidget.appex/Contents/Info.plist" CFBundleIdentifier)"
  export APP_BUNDLE_IDENTIFIER APP_GROUP_IDENTIFIER WIDGET_BUNDLE_IDENTIFIER
fi

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  export INCLUDE_LOCAL_MENU_ICON="${INCLUDE_LOCAL_MENU_ICON:-1}"
  "$ROOT/Scripts/package.sh"
fi
codesign --verify --deep --strict "$BUILT_APP"
# Reject a public/default-identity build before stopping an existing private app.
if [[ -d "$INSTALLED_APP" ]]; then
  if [[ "$(plist_value "$BUILT_APP/Contents/Info.plist" CFBundleIdentifier)" != "$APP_BUNDLE_IDENTIFIER" \
     || "$(plist_value "$BUILT_APP/Contents/Info.plist" CodexUsageAppGroupIdentifier)" != "$APP_GROUP_IDENTIFIER" \
     || "$(plist_value "$BUILT_APP/Contents/PlugIns/CodexMonitorWidget.appex/Contents/Info.plist" CFBundleIdentifier)" != "$WIDGET_BUNDLE_IDENTIFIER" ]]; then
    printf '%s\n' 'App, widget or App Group identity differs; installation stopped.' >&2
    exit 1
  fi
fi

mkdir -p "$INSTALL_DIRECTORY"
STAGING_DIRECTORY="$(mktemp -d "$INSTALL_DIRECTORY/.codex-monitor-install.XXXXXX")"
REPLACEMENT_STARTED=0
INSTALL_SUCCEEDED=0
MONITOR_STOPPED=0
cleanup() {
  local status=$?
  if [[ "$INSTALL_SUCCEEDED" != "1" ]]; then
    if [[ "$REPLACEMENT_STARTED" == "1" ]]; then
      if [[ -d "$INSTALLED_APP" ]]; then
        mv "$INSTALLED_APP" "$STAGING_DIRECTORY/failed.app" || return 1
      fi
      if [[ -d "$STAGING_DIRECTORY/previous.app" ]]; then
        if ! mv "$STAGING_DIRECTORY/previous.app" "$INSTALLED_APP"; then
          printf 'Rollback retained for recovery: %s\n' "$STAGING_DIRECTORY" >&2
          return 1
        fi
      fi
    fi
    if [[ "$MONITOR_STOPPED" == "1" && -d "$INSTALLED_APP" ]]; then
      open -g "$INSTALLED_APP" || true
    fi
  fi
  rm -rf "$STAGING_DIRECTORY"
  return "$status"
}
trap cleanup EXIT

ditto "$BUILT_APP" "$STAGING_DIRECTORY/Codex Monitor.app"
codesign --verify --deep --strict "$STAGING_DIRECTORY/Codex Monitor.app"
if [[ -d "$INSTALLED_APP" ]]; then
  mkdir -p "$(dirname "$BACKUP_ARCHIVE")"
  ditto -c -k --sequesterRsrc --keepParent "$INSTALLED_APP" "$BACKUP_ARCHIVE"
  unzip -tqq "$BACKUP_ARCHIVE"
fi

if pgrep -x 'Codex Monitor' >/dev/null; then
  MONITOR_STOPPED=1
  pkill -TERM -x 'Codex Monitor' || true
  for attempt in {1..50}; do
    if ! pgrep -x 'Codex Monitor' >/dev/null; then break; fi
    sleep 0.1
  done
  if pgrep -x 'Codex Monitor' >/dev/null; then
    printf '%s\n' 'Codex Monitor is still running; installation stopped.' >&2
    exit 1
  fi
fi

if [[ -d "$INSTALLED_APP" ]]; then
  mv "$INSTALLED_APP" "$STAGING_DIRECTORY/previous.app"
fi
REPLACEMENT_STARTED=1
mv "$STAGING_DIRECTORY/Codex Monitor.app" "$INSTALLED_APP"
codesign --verify --deep --strict "$INSTALLED_APP"
open -g "$INSTALLED_APP"
INSTALL_SUCCEEDED=1
printf 'Installed: %s\n' "$INSTALLED_APP"
if [[ -f "$BACKUP_ARCHIVE" ]]; then
  printf 'Previous version: %s\n' "$BACKUP_ARCHIVE"
fi
