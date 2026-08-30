#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --spec project.yml
elif [[ -d "$ROOT/CodexUsageBar.xcodeproj" ]]; then
  printf '%s\n' \
    "XcodeGen is not installed; using the checked-in Xcode project." \
    "Install XcodeGen only when project.yml needs to be regenerated."
else
  printf '%s\n' \
    "CodexUsageBar.xcodeproj is missing and XcodeGen is not installed." \
    "Install it with: brew install xcodegen" \
    >&2
  exit 1
fi
