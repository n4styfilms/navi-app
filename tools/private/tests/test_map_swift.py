"""Real Swift policy tests. Apple SDK/runtime checks remain separate."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class SwiftMapTests(unittest.TestCase):
    def test_configuration_and_generation_lifecycle(self):
        swift = os.environ.get('NAVI_SWIFTC') or shutil.which('swiftc')
        if not swift:
            self.skipTest('Swift compiler unavailable; run on macOS runner')
        root = Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory(prefix='navi-map-swift-') as directory:
            executable = Path(directory) / ('map.exe' if os.name == 'nt' else 'map')
            built = subprocess.run([swift, str(root / 'iphone/Maps/UI/NaviMap/NaviMapPolicy.swift'),
                                    str(Path(__file__).with_name('MapSwiftProbe.swift')),
                                    '-o', str(executable)], capture_output=True, text=True, timeout=180)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS Swift map', result.stdout)
