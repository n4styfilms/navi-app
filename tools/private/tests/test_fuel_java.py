"""Run the real Android domain calculator on the host JDK using shared literal cases."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class JavaFuelTests(unittest.TestCase):
    def test_shared_fuel_cases(self):
        suffix = '.exe' if os.name == 'nt' else ''
        java_home = os.environ.get('JAVA_HOME')
        javac = shutil.which('javac')
        java = shutil.which('java')
        if java_home:
            javac = str(Path(java_home) / 'bin' / ('javac' + suffix))
            java = str(Path(java_home) / 'bin' / ('java' + suffix))
        if not javac or not java:
            self.skipTest('JDK unavailable; set JAVA_HOME')
        root = Path(__file__).resolve().parents[3]
        domain = root / 'android/app/src/main/java/app/organicmaps/fuel'
        sources = [domain / name for name in ('VehicleProfile.java', 'FuelEstimate.java', 'FuelCalculator.java')]
        with tempfile.TemporaryDirectory(prefix='navi-fuel-') as directory:
            built = subprocess.run([javac, '-d', directory, *(str(p) for p in sources),
                                    str(Path(__file__).with_name('FuelProbe.java'))],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            cases = json.loads((root / 'testing/private/fuel-cases.json').read_text(encoding='utf-8'))
            cases.append({'name': 'missing_profile', 'distanceMeters': 1000, 'wltp': 'NO_PROFILE',
                          'price': None, 'personal': None, 'status': 'NEED_PROFILE'})
            for case in cases:
                with self.subTest(case=case['name']):
                    values = [case[key] for key in ('distanceMeters', 'wltp', 'price', 'personal')]
                    arguments = ['null' if value is None else str(value) for value in values]
                    result = subprocess.run([java, '-cp', directory, 'FuelProbe', *arguments],
                                            capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    fields = result.stdout.strip().split('\t')
                    self.assertEqual(fields[0], case['status'])
                    if case['status'] == 'READY':
                        self.assertEqual(len(fields), 4)
                        self.assertAlmostEqual(float(fields[1]), case['liters'], places=10)
                        self.assertAlmostEqual(float(fields[2]), case['euros'], places=10)
                        self.assertEqual(fields[3], case['source'])
                    else:
                        self.assertEqual(len(fields), 1)
