import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class FriendsGroupSwiftTests(unittest.TestCase):
    def test_actual_swift_group_configuration(self):
        if sys.platform != 'darwin':
            self.skipTest('Apple Swift required; run on the standard macOS host runner')
        swift = os.environ.get('NAVI_SWIFTC') or shutil.which('swiftc')
        if not swift:
            self.skipTest('Swift compiler unavailable')
        root = Path(__file__).resolve().parents[3]
        source = root / 'iphone/Maps/UI/NaviFriends/FriendsGroupConfiguration.swift'
        with tempfile.TemporaryDirectory(prefix='navi-friends-group-') as directory:
            binary = Path(directory) / 'friends-group'
            compiled = subprocess.run([swift, '-parse-as-library', str(source),
                str(Path(__file__).with_name('FriendsGroupConfigurationProbe.swift')), '-o', str(binary)],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            executed = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
            self.assertEqual(executed.returncode, 0, executed.stdout + executed.stderr)
            self.assertIn('32 invalid blocks rejected', executed.stdout)
