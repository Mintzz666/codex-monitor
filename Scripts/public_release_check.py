#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
IGNORED_PARTS = {
    ".DS_Store",
    ".git",
    ".build",
    ".swiftpm",
    ".wrangler",
    "dist",
    "node_modules",
    "xcuserdata",
}
REQUIRED_PATHS = {
    ".github/workflows/ci.yml",
    ".github/workflows/release.yml",
    "CONTRIBUTING.md",
    "LICENSE",
    "NOTICE.md",
    "Package.swift",
    "README.md",
    "README.zh-CN.md",
    "SECURITY.md",
    "Mobile/README.md",
    "Scripts/package.sh",
    "Scripts/release_package.sh",
    "Sources/CodexUsageShared/EPDTransport.swift",
    "Sources/CodexUsageShared/NRFEPDBluetoothTransport.swift",
    "docs/architecture-and-privacy.md",
    "docs/images/epd-live-preview.png",
    "docs/images/mobile-v1.2-preview.png",
    "docs/images/usage-popover.png",
    "docs/release-notes/v1.4.1.md",
    "docs/setup-epd.md",
    "docs/setup-ios.md",
    "docs/setup-macos.md",
    "project.yml",
}
FORBIDDEN_SUFFIXES = {
    ".cer",
    ".key",
    ".mobileprovision",
    ".p12",
    ".pem",
}
FORBIDDEN_NAMES = {
    ".env",
    ".netrc",
    "id_ed25519",
    "id_rsa",
}
FORBIDDEN_PATTERNS = {
    "absolute macOS user path": re.compile(rb"/Users/[A-Za-z0-9._-]+/"),
    "private workspace path": re.compile(rb"/opt/workspace"),
    "OpenAI-style secret": re.compile(rb"\bsk-(?:proj-)?[A-Za-z0-9_-]{16,}\b"),
    "GitHub token": re.compile(rb"\bgh[opusr]_[A-Za-z0-9]{16,}\b"),
    "private key": re.compile(rb"BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY"),
    "bearer credential": re.compile(rb"Bearer\s+[A-Za-z0-9._~-]{20,}"),
    "personal bundle marker": re.compile(
        rb"(?:com|group\.com)\.mintzz", re.IGNORECASE
    ),
    "personal email marker": re.compile(rb"baishuidream@gmail\.com", re.IGNORECASE),
    "chat attachment path": re.compile(rb"(?:wxid_|xwechat_files)"),
    "hard-coded Apple Team ID": re.compile(
        rb"DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}"
    ),
}


def iter_public_files() -> list[Path]:
    files: list[Path] = []
    this_script = Path(__file__).resolve()
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.resolve() == this_script:
            continue
        relative = path.relative_to(ROOT)
        if any(part in IGNORED_PARTS for part in relative.parts):
            continue
        files.append(path)
    return files


def main() -> int:
    failures: list[str] = []

    for relative_path in sorted(REQUIRED_PATHS):
        if not (ROOT / relative_path).is_file():
            failures.append(f"missing required file: {relative_path}")

    for path in iter_public_files():
        relative = path.relative_to(ROOT)
        if path.name in FORBIDDEN_NAMES or path.suffix.lower() in FORBIDDEN_SUFFIXES:
            failures.append(f"{relative}: forbidden credential file")
            continue

        try:
            data = path.read_bytes()
        except OSError as error:
            failures.append(f"{relative}: could not read ({error})")
            continue

        for label, pattern in FORBIDDEN_PATTERNS.items():
            if pattern.search(data):
                failures.append(f"{relative}: {label}")

    if failures:
        print("Public release check failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print("Public release check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
