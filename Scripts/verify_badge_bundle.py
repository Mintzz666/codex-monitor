#!/usr/bin/env python3
"""Verify the pinned Codex Usage Badge files embedded in Codex Monitor."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "Resources" / "CodexUsageBadge"
MANIFEST = BUNDLE / "manifest.json"
PINNED_SHA256 = "d6e1b2d1cff2ef63964fe7b31797357d0ff25c397bdb66de351c87b1a48541db"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


RUNTIME_FILES = [
    "agent.cjs", "manage.cjs", "network-agent.cjs", "shared-quota.cjs",
    "macos/shortcuts.cjs", "macos/startup/bridge",
    "macos/startup/controller.cjs", "macos/startup/watch.cjs",
]
PACKAGE_FILES = [*RUNTIME_FILES, "health.cjs", "network-health.cjs", "LICENSE", "NOTICE.md"]


def all_files(directory: Path = BUNDLE) -> dict[str, str]:
    return {
        path.relative_to(directory).as_posix(): sha256(path)
        for path in sorted(directory.rglob("*"))
        if path.is_file() and path != directory / "manifest.json"
    }


def make_manifest(files: dict[str, str]) -> dict[str, object]:
    record_path = BUNDLE / "local-customization/project-thread-color/当前优化版记录.json"
    record = json.loads(record_path.read_text(encoding="utf-8"))
    if record.get("sha256") != PINNED_SHA256:
        raise ValueError("The local optimized-build record does not match the pinned hash.")
    if files.get("agent.cjs") != PINNED_SHA256:
        raise ValueError("The bundled agent.cjs does not match the pinned optimized build.")

    runtime_files = RUNTIME_FILES
    missing = [name for name in PACKAGE_FILES if name not in files]
    if missing:
        raise ValueError("Required runtime files are missing: " + ", ".join(missing))
    return {
        "schemaVersion": 1,
        "product": "Codex Usage Badge",
        "upstreamVersion": "0.9.1",
        "buildId": "mintzz-optimized-gpt-folder-sync-sg-sin",
        "pinnedAgentSHA256": PINNED_SHA256,
        "originalRepository": "https://github.com/jaykinhoo9/codex-usage-badge",
        "license": "MIT",
        "runtimeFiles": runtime_files,
        "files": files,
    }


def packaged_manifest(source_manifest: dict[str, object]) -> dict[str, object]:
    return {
        **source_manifest,
        "files": {name: source_manifest["files"][name] for name in sorted(PACKAGE_FILES)},
    }


def verify_package(directory: Path, expected: dict[str, object]) -> None:
    current = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    if current != expected or all_files(directory) != expected["files"]:
        raise ValueError("Packaged Badge files or manifest do not match the release allowlist.")


def stage_package(destination: Path, expected: dict[str, object]) -> None:
    # A fresh directory prevents stale development files leaking into releases.
    destination.mkdir(parents=True, exist_ok=False)
    for name in PACKAGE_FILES:
        source = BUNDLE / name
        if source.is_symlink():
            raise ValueError(f"Refusing to package a symbolic link: {name}")
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    (destination / "manifest.json").write_text(
        json.dumps(expected, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    verify_package(destination, expected)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true", help="Regenerate the resource manifest after an intentional update.")
    parser.add_argument("--stage", type=Path, help="Stage runtime-only resources into a new directory.")
    parser.add_argument("--verify-package", type=Path, help="Verify staged runtime resources against source.")
    args = parser.parse_args()
    if args.write and (args.stage or args.verify_package):
        parser.error("--write cannot be combined with staging or package verification")

    try:
        files = all_files()
        expected = make_manifest(files)
        if args.write:
            MANIFEST.write_text(json.dumps(expected, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            print(f"Wrote manifest for {len(files)} bundled files.")
            return 0
        current = json.loads(MANIFEST.read_text(encoding="utf-8"))
        if current != expected:
            print("Badge resource manifest is stale or files have changed; review changes before packaging.", file=sys.stderr)
            return 1
        release_manifest = packaged_manifest(expected)
        if args.stage:
            stage_package(args.stage, release_manifest)
            print(f"Staged {len(PACKAGE_FILES)} release files; development history stays in source.")
        if args.verify_package:
            verify_package(args.verify_package, release_manifest)
            print("Packaged Badge allowlist and hashes verified.")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Badge resource verification failed: {error}", file=sys.stderr)
        return 1

    print(f"Badge resource verification passed: {len(expected['files'])} files; pinned agent hash matches.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
