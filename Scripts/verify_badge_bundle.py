#!/usr/bin/env python3
"""Verify the pinned Codex Usage Badge files embedded in Codex Monitor."""

from __future__ import annotations

import argparse
import hashlib
import json
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


def all_files() -> dict[str, str]:
    return {
        path.relative_to(BUNDLE).as_posix(): sha256(path)
        for path in sorted(BUNDLE.rglob("*"))
        if path.is_file() and path != MANIFEST
    }


def make_manifest(files: dict[str, str]) -> dict[str, object]:
    record_path = BUNDLE / "local-customization/project-thread-color/当前优化版记录.json"
    record = json.loads(record_path.read_text(encoding="utf-8"))
    if record.get("sha256") != PINNED_SHA256:
        raise ValueError("The local optimized-build record does not match the pinned hash.")
    if files.get("agent.cjs") != PINNED_SHA256:
        raise ValueError("The bundled agent.cjs does not match the pinned optimized build.")

    runtime_files = [
        "agent.cjs",
        "manage.cjs",
        "network-agent.cjs",
        "shared-quota.cjs",
        "macos/shortcuts.cjs",
        "macos/startup/bridge",
        "macos/startup/controller.cjs",
        "macos/startup/watch.cjs",
        *sorted(name for name in files if name.startswith("local-customization/project-thread-color/")),
    ]
    missing = [name for name in runtime_files if name not in files]
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true", help="Regenerate the resource manifest after an intentional update.")
    args = parser.parse_args()

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
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Badge resource verification failed: {error}", file=sys.stderr)
        return 1

    print(f"Badge resource verification passed: {len(expected['files'])} files; pinned agent hash matches.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
