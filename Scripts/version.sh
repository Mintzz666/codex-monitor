#!/usr/bin/env bash
# project.yml is the version source for builds, DMGs, installers and CI.
VERSION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-$(awk '/MARKETING_VERSION:/{print $2; exit}' "$VERSION_ROOT/project.yml")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(awk '/CURRENT_PROJECT_VERSION:/{print $2; exit}' "$VERSION_ROOT/project.yml")}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  printf '%s\n' 'Invalid release version or build number.' >&2
  return 1 2>/dev/null || exit 1
fi
export VERSION BUILD_NUMBER
