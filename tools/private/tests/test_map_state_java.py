import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class MapStateJavaTests(unittest.TestCase):
    def test_configuration_authentication_and_load_lifecycle(self):
        suffix = '.exe' if os.name == 'nt' else ''
        home = os.environ.get('JAVA_HOME')
        javac = str(Path(home) / 'bin' / ('javac' + suffix)) if home else shutil.which('javac')
        java = str(Path(home) / 'bin' / ('java' + suffix)) if home else shutil.which('java')
        if not javac or not java:
            self.skipTest('JDK required')
        root = Path(__file__).resolve().parents[3]
        domain = root / 'android/app/src/main/java/app/organicmaps/navi/map'
        with tempfile.TemporaryDirectory(prefix='navi-map-state-') as directory:
            result = subprocess.run([javac, '-encoding', 'UTF-8', '-d', directory,
                *(str(domain / source) for source in ('BasemapMode.java', 'EsriMapConfiguration.java', 'MapLoadState.java')),
                str(Path(__file__).with_name('MapStateProbe.java'))], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([java, '-cp', directory, 'MapStateProbe'], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS map setup, authenticated child requests', result.stdout)
