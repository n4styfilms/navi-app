import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class MapTransportJavaTests(unittest.TestCase):
    def test_actual_okhttp_failure_boundaries(self):
        cache = Path(os.environ.get('GRADLE_USER_HOME', Path.home() / '.gradle')) / 'caches/modules-2/files-2.1'
        coordinates = ['com.squareup.okhttp3/okhttp/4.12.0', 'com.squareup.okio/okio-jvm/3.6.0',
                       'org.jetbrains.kotlin/kotlin-stdlib/2.2.20', 'org.json/json/20240303']
        jars = [next((cache / coordinate).glob('*/*.jar'), None) for coordinate in coordinates]
        home = os.environ.get('JAVA_HOME')
        suffix = '.exe' if os.name == 'nt' else ''
        javac = str(Path(home) / 'bin' / ('javac' + suffix)) if home else shutil.which('javac')
        java = str(Path(home) / 'bin' / ('java' + suffix)) if home else shutil.which('java')
        if not javac or not java or not all(jars):
            self.skipTest('Host requires JDK and cached pinned OkHttp/Okio/Kotlin/JSON; Gradle also runs EsriTransportTest')
        root = Path(__file__).resolve().parents[3]
        domain = root / 'android/app/src/main/java/app/organicmaps/navi/map'
        with tempfile.TemporaryDirectory(prefix='navi-map-http-') as directory:
            cp = os.pathsep.join(map(str, jars))
            command = [javac, '-encoding', 'UTF-8', '-cp', cp, '-d', directory,
                       *(str(domain / source) for source in ['BasemapMode.java', 'EsriMapConfiguration.java',
                                                             'MapLoadState.java', 'EsriHttpClient.java']),
                       str(root / 'android/app/src/test/java/app/organicmaps/navi/map/EsriTransportProbe.java')]
            result = subprocess.run(command, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([java, '-cp', directory + os.pathsep + cp,
                                     'app.organicmaps.navi.map.EsriTransportProbe'],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS real OkHttp map transport', result.stdout)
