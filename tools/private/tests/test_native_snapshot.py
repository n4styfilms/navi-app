"""Compile and run the real, dependency-free C++ route boundary on this host."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class NativeSnapshotTests(unittest.TestCase):
    def test_route_snapshot_rejects_stale_results_and_preserves_values(self):
        compiler = (os.environ.get('NAVI_CXX') or os.environ.get('CXX')
                    or shutil.which('clang++') or shutil.which('g++'))
        if not compiler:
            self.skipTest('Host C++ compiler unavailable; set NAVI_CXX')
        compiler = shutil.which(compiler) or compiler
        sdk = os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME')
        suffix = '.exe' if os.name == 'nt' else ''
        cmake = os.environ.get('NAVI_CMAKE') or shutil.which('cmake')
        ninja = shutil.which('ninja')
        if sdk:
            sdk_tools = Path(sdk) / 'cmake/3.22.1/bin'
            cmake = cmake or str(sdk_tools / ('cmake' + suffix))
            ninja = ninja or str(sdk_tools / ('ninja' + suffix))
        self.assertTrue(cmake, 'CMake required to exercise production numerical compiler configuration')
        with tempfile.TemporaryDirectory(prefix='navi-snapshot-') as directory:
            build = Path(directory)
            executable = build / ('snapshot_tests' + suffix)
            configure = [cmake, '-S', str(Path(__file__).with_name('snapshot-build')),
                         '-B', str(build), '-DCMAKE_BUILD_TYPE=Release',
                         '-DCMAKE_CXX_COMPILER=' + Path(compiler).as_posix()]
            if ninja:
                configure.extend(['-G', 'Ninja', '-DCMAKE_MAKE_PROGRAM=' + Path(ninja).as_posix()])
            for command in (configure, [cmake, '--build', str(build)]):
                built = subprocess.run(command, capture_output=True, text=True, timeout=180)
                self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS 7 snapshot behavior cases', result.stdout)
