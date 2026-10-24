"""Run the same consent-generation, cadence and quality traces in production Java/Swift."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
PROBES = Path(__file__).resolve().parent


class PresencePolicyTests(unittest.TestCase):
    def check_cases(self, command):
        cases = json.loads((ROOT / 'testing/private/presence-cases.json').read_text(encoding='utf-8'))
        self.assertGreaterEqual(len(cases), 25)
        for case in cases:
            with self.subTest(case=case['name']):
                def token(value):
                    if value is None: return 'null'
                    if isinstance(value, bool): return str(value).lower()
                    return str(value)
                data = ''.join('\t'.join(map(token, event['command'])) + '\n' for event in case['events'])
                result = subprocess.run(command, input=data, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                rows = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
                self.assertEqual(len(rows), len(case['events']))
                for actual, event in zip(rows, case['events']):
                    for field, expected in event['expect'].items():
                        self.assertEqual(actual.get(field), expected, (case['name'], event['command'], field, actual))

    def test_java_shared_traces(self):
        suffix = '.exe' if os.name == 'nt' else ''
        java_home = os.environ.get('JAVA_HOME')
        java = str(Path(java_home) / 'bin' / ('java' + suffix)) if java_home else shutil.which('java')
        javac = str(Path(java_home) / 'bin' / ('javac' + suffix)) if java_home else shutil.which('javac')
        if not java or not javac: self.skipTest('JDK unavailable; set JAVA_HOME')
        domain = ROOT / 'android/app/src/main/java/app/organicmaps/navi/friends'
        with tempfile.TemporaryDirectory(prefix='navi-presence-java-') as directory:
            result = subprocess.run([javac, '-d', directory, str(domain / 'PresenceSample.java'),
                str(domain / 'PresencePolicy.java'), str(PROBES / 'PresenceProbe.java')],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.check_cases([java, '-cp', directory, 'PresenceProbe'])

    def test_swift_shared_traces(self):
        if sys.platform != 'darwin': self.skipTest('Run actual Apple Swift presence traces on macOS runner')
        swift = os.environ.get('NAVI_SWIFTC') or shutil.which('swiftc')
        if not swift: self.skipTest('Swift compiler unavailable')
        domain = ROOT / 'iphone/Maps/UI/NaviFriends'
        with tempfile.TemporaryDirectory(prefix='navi-presence-swift-') as directory:
            binary = Path(directory) / 'presence'
            result = subprocess.run([swift, '-parse-as-library', str(domain / 'PresenceSample.swift'),
                str(domain / 'PresencePolicy.swift'), str(PROBES / 'PresenceSwiftProbe.swift'), '-o', str(binary)],
                capture_output=True, text=True, timeout=180)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.check_cases([str(binary)])


if __name__ == '__main__': unittest.main()
