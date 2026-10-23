"""Compile the real Foundation domain where Swift exists; Apple app/UI proof is separate."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class SwiftFuelTests(unittest.TestCase):
    def test_shared_cases_and_store_across_processes(self):
        swift = os.environ.get('NAVI_SWIFTC') or shutil.which('swiftc')
        if not swift:
            self.skipTest('Swift compiler unavailable; run on the macOS build runner')
        root = Path(__file__).resolve().parents[3]
        source = root / 'iphone/Maps/Model/Fuel/NaviFuel.swift'
        with tempfile.TemporaryDirectory(prefix='navi-fuel-swift-') as directory:
            executable = Path(directory) / ('fuel.exe' if os.name == 'nt' else 'fuel')
            built = subprocess.run([swift, str(source), str(Path(__file__).with_name('FuelSwiftProbe.swift')),
                                    '-o', str(executable)], capture_output=True, text=True, timeout=180)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            for mode, path in [('fuel', root / 'testing/private/fuel-cases.json'),
                               ('input', root / 'testing/private/vehicle-input-cases.json'),
                               ('write', Path(directory) / 'profile/vehicle.json'),
                               ('read', Path(directory) / 'profile/vehicle.json'),
                               ('delete', Path(directory) / 'profile/vehicle.json')]:
                with self.subTest(mode=mode):
                    result = subprocess.run([str(executable), mode, str(path)], capture_output=True,
                                            text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn('PASS Swift', result.stdout)
