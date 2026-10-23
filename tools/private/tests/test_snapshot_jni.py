"""Real JVM loads the production C++ mapper. No Framework, GPS or Android app is mocked into this evidence."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class SnapshotJniTests(unittest.TestCase):
    def test_production_mapper_and_java_immutable_values(self):
        compiler = os.environ.get('NAVI_CXX') or os.environ.get('CXX') or shutil.which('g++')
        java_home = os.environ.get('JAVA_HOME')
        if not compiler or not java_home:
            self.skipTest('Set NAVI_CXX and JAVA_HOME for real JNI/JVM mapping test')
        root = Path(__file__).resolve().parents[3]
        test_dir = Path(__file__).resolve().parent
        jdk = Path(java_home)
        jni_include = Path(os.environ.get('NAVI_JNI_INCLUDE', str(jdk / 'include')))
        suffix = '.exe' if os.name == 'nt' else ''
        java = jdk / 'bin' / ('java' + suffix)
        javac = jdk / 'bin' / ('javac' + suffix)
        cpp = root / 'android/sdk/src/main/cpp'
        with tempfile.TemporaryDirectory(prefix='navi-jni-') as temporary:
            build = Path(temporary)
            annotation = build / 'Keep.java'
            annotation.write_text('package androidx.annotation; public @interface Keep {}', encoding='utf-8')
            compiled = subprocess.run([str(javac), '-encoding', 'UTF-8', '-d', str(build), str(annotation),
                str(root / 'android/sdk/src/main/java/app/organicmaps/sdk/routing/NaviRouteSnapshot.java'),
                str(test_dir / 'SnapshotProbe.java')], capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            library = build / ('snapshot_probe.dll' if os.name == 'nt' else 'libsnapshot_probe.so')
            flags = ['-static'] if os.name == 'nt' else ['-fPIC']
            jni_platform = 'win32' if os.name == 'nt' else 'darwin' if sys.platform == 'darwin' else 'linux'
            command = [compiler, '-std=c++20', '-shared', *flags, '-O2', '-Wall', '-Wextra',
                '-I' + str(jni_include), '-I' + str(jni_include / jni_platform),
                '-I' + str(cpp), '-I' + str(root / 'libs'), '-I' + str(root),
                str(cpp / 'app/organicmaps/sdk/routing/NaviRouteSnapshot.cpp'),
                str(test_dir / 'navi_snapshot_jni_probe.cpp'), '-o', str(library)]
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(java), '-Xcheck:jni', '-cp', str(build), 'SnapshotProbe', str(library)],
                                    capture_output=True, text=True, encoding='utf-8', timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn('WARNING', result.stdout + result.stderr)
            self.assertIn('PASS production JNI snapshot mapping', result.stdout)
