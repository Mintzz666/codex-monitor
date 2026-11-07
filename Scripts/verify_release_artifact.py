#!/usr/bin/env python3
"""Read-only verification of the universal app and the app inside its DMG."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True, capture_output=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(app):
    return {p.relative_to(app).as_posix(): digest(p)
            for p in sorted(app.rglob("*")) if p.is_file()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=ROOT / "dist/Codex Monitor.app")
    parser.add_argument("--dmg", type=Path)
    parser.add_argument("--allow-private-identity", action="store_true")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    spec = (ROOT / "project.yml").read_text()
    version = os.environ.get("VERSION") or re.search(r"MARKETING_VERSION:\s*(\S+)", spec).group(1)
    build = os.environ.get("BUILD_NUMBER") or re.search(r"CURRENT_PROJECT_VERSION:\s*(\S+)", spec).group(1)
    dmg = args.dmg or ROOT / f"dist/Codex-Monitor-v{version}-universal.dmg"
    checksum = Path(str(dmg) + ".sha256").read_text().strip().split(maxsplit=1)
    assert len(checksum) == 2 and checksum[1].lstrip("*") == dmg.name, "Wrong checksum filename"
    assert digest(dmg) == checksum[0], "DMG checksum mismatch"
    bundle_spec = importlib.util.spec_from_file_location("badge_bundle", ROOT / "Scripts/verify_badge_bundle.py")
    bundle = importlib.util.module_from_spec(bundle_spec)
    bundle_spec.loader.exec_module(bundle)
    expected = bundle.packaged_manifest(bundle.make_manifest(bundle.all_files()))

    def verify_app(app):
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
        widget = app / "Contents/PlugIns/CodexMonitorWidget.appex"
        for target, executable, identifier in [
            (app, "Codex Monitor", "com.example.codexmonitor"),
            (widget, "CodexMonitorWidget", "com.example.codexmonitor.widget"),
        ]:
            info = plistlib.loads((target / "Contents/Info.plist").read_bytes())
            assert info["CFBundleShortVersionString"] == version, "Wrong app/widget version"
            assert info["CFBundleVersion"] == build, "Wrong app/widget build number"
            if not args.allow_private_identity:
                assert info["CFBundleIdentifier"] == identifier, "Non-public bundle identifier"
                assert info["CodexUsageAppGroupIdentifier"] == "group.com.example.codexmonitor", "Non-public App Group"
            binary = target / "Contents/MacOS" / executable
            run("/usr/bin/lipo", binary, "-verify_arch", "arm64", "x86_64")
            assert not re.search(rb"/Users/[A-Za-z0-9._-]+/|/opt[/]workspace", binary.read_bytes()), "Build path embedded in executable"
        bundle.verify_package(app / "Contents/Resources/CodexUsageBadge", expected)
        assert not (app / "Contents/Resources/AppIcon-1024.png").exists(), "Source PNG leaked into runtime"
        if not args.allow_private_identity:
            assert not (app / "Contents/Resources/OfficialCodexMenuTemplate.png").exists(), "Local artwork in public app"

    verify_app(args.app)
    files = inventory(args.app)
    temporary = Path(tempfile.mkdtemp(prefix="monitor-release-verify-"))
    mount = temporary / "mount"
    mount.mkdir()
    mounted = False
    try:
        run("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, dmg)
        mounted = True
        packaged_app = mount / "Codex Monitor.app"
        verify_app(packaged_app)
        assert inventory(packaged_app) == files, "DMG app differs from verified build"
    finally:
        if mounted:
            run("/usr/bin/hdiutil", "detach", mount)
        shutil.rmtree(temporary)
    result = {"version": version, "build": build, "signatureValid": True,
              "architectures": ["arm64", "x86_64"], "badgeAllowlistValid": True,
              "publicIdentity": not args.allow_private_identity,
              "appFileCount": len(files),
              "appBytes": sum(p.stat().st_size for p in args.app.rglob("*") if p.is_file()),
              "dmgBytes": dmg.stat().st_size, "dmgSHA256": digest(dmg),
              "dmgMatchesBuiltApp": True}
    if args.report:
        args.report.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
