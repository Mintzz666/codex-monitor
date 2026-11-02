"""Release selection must preserve runnable helpers and reject incomplete bundles."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "badge_bundle", Path(__file__).resolve().parents[1] / "Scripts/verify_badge_bundle.py"
)
bundle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bundle)


class BadgePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.destination = Path(self.temporary.name) / "Badge"
        self.expected = bundle.packaged_manifest(bundle.make_manifest(bundle.all_files()))
        bundle.stage_package(self.destination, self.expected)

    def test_runtime_has_required_helpers_and_licenses_without_development_history(self):
        self.assertFalse((self.destination / "local-customization").exists())
        for name in ["LICENSE", "NOTICE.md", "health.cjs", "network-health.cjs",
                     "macos/startup/bridge", "shared-quota.cjs", "manage.cjs"]:
            self.assertTrue((self.destination / name).is_file(), name)
        self.assertEqual(bundle.sha256(self.destination / "agent.cjs"), bundle.PINNED_SHA256)
        self.assertTrue((bundle.BUNDLE / "local-customization").is_dir())

    def test_missing_runtime_dependency_is_rejected(self):
        (self.destination / "shared-quota.cjs").unlink()
        with self.assertRaises(ValueError):
            bundle.verify_package(self.destination, self.expected)

    def test_tampered_manager_is_rejected(self):
        (self.destination / "manage.cjs").write_text("// altered")
        with self.assertRaises(ValueError):
            bundle.verify_package(self.destination, self.expected)

    def test_unexpected_history_file_is_rejected(self):
        (self.destination / "old-agent.cjs").write_text("// stale build")
        with self.assertRaises(ValueError):
            bundle.verify_package(self.destination, self.expected)

    def test_existing_stage_is_not_overwritten(self):
        with self.assertRaises(FileExistsError):
            bundle.stage_package(self.destination, self.expected)
        bundle.verify_package(self.destination, self.expected)
