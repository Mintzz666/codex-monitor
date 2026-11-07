"""Install failures must preserve the previous app and never touch real processes."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "darwin", "macOS installer")
class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.apps = self.base / "Applications"
        self.installed = self.apps / "Codex Monitor.app"
        self.built = self.base / "built.app"
        self.commands = self.base / "bin"
        self.commands.mkdir()
        self.make_app(self.installed, "old")
        self.make_app(self.built, "new")
        mock = '''#!/usr/bin/env python3
import json,os,pathlib,sys
name=pathlib.Path(sys.argv[0]).name
root=pathlib.Path(os.environ['FIXTURE_ROOT'])
with (root/'commands.jsonl').open('a') as f: f.write(json.dumps([name,*sys.argv[1:]])+'\\n')
if name=='pgrep': sys.exit(1)
if name=='pkill': raise RuntimeError('must never stop real processes')
if name=='codesign' and os.environ.get('FAIL_INSTALLED_SIGNATURE')=='1':
    if sys.argv[-1]==str(root/'Applications/Codex Monitor.app'): sys.exit(1)
if name=='open' and os.environ.get('FAIL_OPEN')=='1': sys.exit(1)
'''
        for name in ["codesign", "pgrep", "pkill", "open"]:
            p = self.commands / name
            p.write_text(mock)
            p.chmod(0o755)

    def make_app(self, app, marker, identifier="com.example.codexmonitor"):
        info = app / "Contents/Info.plist"
        widget = app / "Contents/PlugIns/CodexMonitorWidget.appex/Contents/Info.plist"
        widget.parent.mkdir(parents=True, exist_ok=True)
        info.write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identifier,
            "CodexUsageAppGroupIdentifier": "group.com.example.codexmonitor",
        }))
        widget.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.example.codexmonitor.widget"}))
        (app / "marker").write_text(marker)

    def install(self, **overrides):
        env = {**os.environ, "PATH": str(self.commands) + os.pathsep + os.environ["PATH"],
               "SKIP_BUILD": "1", "BUILT_APP_PATH": str(self.built),
               "INSTALL_DIRECTORY": str(self.apps),
               "INSTALL_BACKUP_DIRECTORY": str(self.base / "backups"),
               "FIXTURE_ROOT": str(self.base), **overrides}
        return subprocess.run(["bash", str(ROOT / "Scripts/install.sh")], env=env,
                              capture_output=True, text=True, timeout=20)

    def test_verified_upgrade_keeps_artifact_and_backup(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.installed / "marker").read_text(), "new")
        self.assertEqual((self.built / "marker").read_text(), "new")
        backups = list((self.base / "backups").rglob("*.zip"))
        self.assertEqual(len(backups), 1)
        subprocess.run(["unzip", "-tqq", str(backups[0])], check=True)

    def test_wrong_identity_is_rejected_before_process_check(self):
        self.make_app(self.built, "new", identifier="com.example.other")
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual((self.installed / "marker").read_text(), "old")
        commands = [json.loads(line)[0] for line in (self.base / "commands.jsonl").read_text().splitlines()]
        self.assertNotIn("pgrep", commands)

    def test_signature_failure_after_swap_restores_previous_app(self):
        self.assertNotEqual(self.install(FAIL_INSTALLED_SIGNATURE="1").returncode, 0)
        self.assertEqual((self.installed / "marker").read_text(), "old")

    def test_launch_failure_restores_previous_app(self):
        self.assertNotEqual(self.install(FAIL_OPEN="1").returncode, 0)
        self.assertEqual((self.installed / "marker").read_text(), "old")
