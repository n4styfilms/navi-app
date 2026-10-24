"""Select only the intended built application before attaching a simulator debugger."""
from pathlib import Path
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'collect_ios_failure.py'


class IOSFailureCollectionTests(unittest.TestCase):
    def app(self, derived, name, identifier):
        app = Path(derived) / 'Build/Products/Debug-iphonesimulator' / (name + '.app')
        app.mkdir(parents=True)
        (app / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': identifier, 'CFBundleExecutable': name}))
        (app / name).write_bytes(b'test fixture; never executed')
        return app.resolve()

    def select(self, derived):
        return subprocess.run([sys.executable, str(SCRIPT), '--select-app', str(derived)],
                              capture_output=True, text=True, timeout=10)

    def test_selects_navi_and_excludes_other_built_apps(self):
        with tempfile.TemporaryDirectory() as directory:
            wanted = self.app(directory, 'CoMaps (Debug)', 'app.navi.private')
            self.app(directory, 'Other', 'example.unrelated')
            result = self.select(directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(Path(json.loads(result.stdout)['app']), wanted)

    def test_missing_app_is_an_explicit_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            self.app(directory, 'Other', 'example.unrelated')
            result = self.select(directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Expected exactly one built app.navi.private application', result.stderr)

    def test_ambiguous_target_does_not_attach_to_an_arbitrary_app(self):
        with tempfile.TemporaryDirectory() as directory:
            self.app(directory, 'First', 'app.navi.private')
            self.app(directory, 'Second', 'app.navi.private')
            result = self.select(directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('found 2', result.stderr)


if __name__ == '__main__':
    unittest.main()
