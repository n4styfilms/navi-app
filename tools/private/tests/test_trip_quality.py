"""Exercise the shared numerical quality boundary under the production finite-math rule."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from pinned_core_headers import ensure_boost


class TripQualityTests(unittest.TestCase):
    def test_native_quality_does_not_invent_continuity_or_speed(self):
        if sys.platform not in ('darwin', 'linux'):
            self.skipTest('Native C++ quality probe runs on the free macOS host runner')
        root = Path(__file__).resolve().parents[3]
        ensure_boost(root)
        cmake = os.environ.get('NAVI_CMAKE') or shutil.which('cmake')
        compiler = os.environ.get('NAVI_CXX') or shutil.which('clang++') or shutil.which('g++')
        self.assertTrue(cmake and compiler, 'Actual CMake and C++ compiler required')
        with tempfile.TemporaryDirectory(prefix='navi-trip-quality-') as directory:
            build = Path(directory)
            for command in ([cmake, '-S', str(Path(__file__).with_name('trip-quality-build')), '-B', str(build),
                             '-DCMAKE_CXX_COMPILER=' + compiler, '-DCMAKE_BUILD_TYPE=Release'],
                            [cmake, '--build', str(build), '--parallel', '2']):
                result = subprocess.run(command, capture_output=True, text=True, timeout=120)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            executed = subprocess.run([str(build / 'trip_quality_probe')], capture_output=True, text=True, timeout=15)
            self.assertEqual(executed.returncode, 0, executed.stdout + executed.stderr)
            self.assertIn('PASS trip quality scenarios', executed.stdout)
