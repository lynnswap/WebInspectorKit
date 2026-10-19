import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "package-cache-key.py"


class PackageCacheKeyTests(unittest.TestCase):
    def test_uses_calling_checkout_tracked_lockfiles_and_appends_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary)
            subprocess.run(["git", "init", "--quiet"], cwd=checkout, check=True)
            tracked = checkout / "App Project/Package.resolved"
            tracked.parent.mkdir()
            tracked.write_text('{"version": 3}\n')
            subprocess.run(["git", "add", "--", "App Project/Package.resolved"],
                           cwd=checkout, check=True)
            output = checkout / "github-output"
            output.write_text("existing=preserved\n")

            def key():
                subprocess.run([sys.executable, str(SCRIPT)], cwd=checkout, check=True,
                               env={**os.environ, "GITHUB_OUTPUT": str(output)},
                               capture_output=True, text=True)
                return output.read_text().splitlines()[-1]

            original = key()
            for path in (".ci/automation/Package.resolved",
                         "SourcePackages/checkouts/dependency/Package.resolved"):
                generated = checkout / path
                generated.parent.mkdir(parents=True)
                generated.write_text('{"untracked": true}\n')
            self.assertEqual(key(), original)

            tracked.write_text('{"version": 3, "pins": []}\n')
            changed = key()
            self.assertNotEqual(changed, original)
            self.assertEqual(key(), changed)
            self.assertEqual(output.read_text().splitlines(), [
                "existing=preserved", original, original, changed, changed
            ])

    def test_tracked_lockfile_path_affects_digest(self):
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary)
            subprocess.run(["git", "init", "--quiet"], cwd=checkout, check=True)
            (checkout / "Package.resolved").write_text('{"version": 3}\n')
            subprocess.run(["git", "add", "--", "Package.resolved"], cwd=checkout, check=True)
            output = checkout / "github-output"

            def key():
                subprocess.run([sys.executable, str(SCRIPT)], cwd=checkout, check=True,
                               env={**os.environ, "GITHUB_OUTPUT": str(output)},
                               capture_output=True, text=True)
                return output.read_text().splitlines()[-1]

            original = key()
            (checkout / "Nested").mkdir()
            subprocess.run(["git", "mv", "--", "Package.resolved", "Nested/Package.resolved"],
                           cwd=checkout, check=True)
            self.assertNotEqual(key(), original)


if __name__ == "__main__":
    unittest.main()
