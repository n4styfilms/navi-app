"""Exercise production Foundation URLSession transport with a protocol fixture on Apple."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class SwiftMapTransportTests(unittest.TestCase):
    def test_actual_urlsession_transport(self):
        if sys.platform != 'darwin':
            self.skipTest('Apple Foundation URLSession transport requires the macOS runner; Linux uses FoundationNetworking')
        swift = os.environ.get('NAVI_SWIFTC') or shutil.which('swiftc')
        if not swift:
            self.skipTest('Swift compiler unavailable; run actual Foundation transport on macOS runner')
        root = Path(__file__).resolve().parents[3]
        source = root / 'iphone/Maps/UI/NaviMap'
        with tempfile.TemporaryDirectory(prefix='navi-map-transport-') as directory:
            binary = Path(directory) / 'transport'
            built = subprocess.run([swift, str(source / 'NaviMapPolicy.swift'),
                                    str(source / 'NaviEsriTransport.swift'),
                                    str(Path(__file__).with_name('MapTransportSwiftProbe.swift')),
                                    '-o', str(binary)], capture_output=True, text=True, timeout=180)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS actual Swift URLSession map transport', result.stdout)
