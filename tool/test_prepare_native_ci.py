"""Verify simulator placeholders without accessing local Firebase configuration."""

import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).with_name("prepare_native_ci.py").resolve()


class NativeConfigurationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp_root = HELPER.parent.parent / "build/native-helper-tests"
        cls.temp_root.mkdir(parents=True, exist_ok=True)

    def run_helper(self, root, ci=True):
        environment = dict(os.environ, GITHUB_ACTIONS="true" if ci else "false")
        return subprocess.run([sys.executable, str(HELPER)], cwd=root,
                              env=environment, capture_output=True, text=True)

    def test_requires_ci_and_preserves_existing_configuration(self):
        with tempfile.TemporaryDirectory(dir=self.temp_root) as directory:
            root = Path(directory)
            (root / "ios").mkdir()
            self.assertNotEqual(self.run_helper(root, ci=False).returncode, 0)
            self.assertFalse((root / "build").exists())
            existing = root / "ios/GoogleService-Info.plist"
            existing.write_text("preserve-me", encoding="utf-8")
            self.assertNotEqual(self.run_helper(root).returncode, 0)
            self.assertEqual(existing.read_text(), "preserve-me")

    def test_generated_configuration_is_nonproduction_and_disables_collection(self):
        with tempfile.TemporaryDirectory(dir=self.temp_root) as directory:
            root = Path(directory)
            (root / "ios").mkdir()
            result = self.run_helper(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            configuration = json.loads((root / "build/native-ci/firebase.json").read_text())
            self.assertTrue(configuration["PROJECT_ID"].startswith("demo-"))
            self.assertEqual(configuration["EMULATOR_HOST"], "127.0.0.1")
            with (root / "ios/GoogleService-Info.plist").open("rb") as stream:
                plist = plistlib.load(stream)
            self.assertEqual(plist["PROJECT_ID"], configuration["PROJECT_ID"])
            self.assertFalse(plist["IS_ANALYTICS_ENABLED"])
            self.assertFalse(plist["IS_ADS_ENABLED"])
            self.assertNotEqual(self.run_helper(root).returncode, 0)


if __name__ == "__main__":
    unittest.main()
