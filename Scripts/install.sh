#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIRECTORY="${INSTALL_DIRECTORY:-/Applications}"
INSTALLED_APP="$INSTALL_DIRECTORY/Codex Monitor.app"
BUILT_APP="$ROOT/dist/Codex Monitor.app"
BACKUP_APP="$ROOT/dist/backups/$(date +%Y%m%d-%H%M%S)/Codex Monitor.app"

# Keep the app identity, desktop widget registration, preferences, and remembered
# Bluetooth device when updating an existing local installation.
if [[ -d "$INSTALLED_APP" ]]; then
  export APP_BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED_APP/Contents/Info.plist")"
  export APP_GROUP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CodexUsageAppGroupIdentifier' "$INSTALLED_APP/Contents/Info.plist")"
  export WIDGET_BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED_APP/Contents/PlugIns/CodexMonitorWidget.appex/Contents/Info.plist")"
fi

"$ROOT/Scripts/package.sh"
codesign --verify --deep --strict "$BUILT_APP"

mkdir -p "$INSTALL_DIRECTORY"
STAGING_DIRECTORY="$(mktemp -d "$INSTALL_DIRECTORY/.codex-monitor-install.XXXXXX")"
trap 'rm -rf "$STAGING_DIRECTORY"' EXIT
ditto "$BUILT_APP" "$STAGING_DIRECTORY/Codex Monitor.app"
codesign --verify --deep --strict "$STAGING_DIRECTORY/Codex Monitor.app"

if [[ -d "$INSTALLED_APP" ]]; then
  mkdir -p "$(dirname "$BACKUP_APP")"
  ditto "$INSTALLED_APP" "$BACKUP_APP"
fi

if pgrep -x 'Codex Monitor' >/dev/null; then
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

# Stage and verify first; retain a rollback copy if replacement fails.
if [[ -d "$INSTALLED_APP" ]]; then
  mv "$INSTALLED_APP" "$STAGING_DIRECTORY/previous.app"
fi
if ! mv "$STAGING_DIRECTORY/Codex Monitor.app" "$INSTALLED_APP"; then
  if [[ -d "$STAGING_DIRECTORY/previous.app" ]]; then
    mv "$STAGING_DIRECTORY/previous.app" "$INSTALLED_APP"
  fi
  exit 1
fi
open "$INSTALLED_APP"
printf 'Installed: %s\n' "$INSTALLED_APP"
if [[ -d "$BACKUP_APP" ]]; then
  printf 'Previous version: %s\n' "$BACKUP_APP"
fi
