"""Exercise the actual pinned CMake/NDK linker, without building the whole app."""
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest


class AndroidLinkerTest(unittest.TestCase):
    def test_ndk_r28_links_arm64_c_and_cpp_with_ipo(self):
        sdk_value = os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME')
        if not sdk_value:
            self.skipTest('Android SDK unavailable on this host')
        sdk = Path(sdk_value)
        extension = '.exe' if os.name == 'nt' else ''
        cmake_bin = sdk / 'cmake/3.22.1/bin'
        cmake = cmake_bin / ('cmake' + extension)
        ninja = cmake_bin / ('ninja' + extension)
        toolchain = sdk / 'ndk/28.2.13676358/build/cmake/android.toolchain.cmake'
        if not all(path.is_file() for path in (cmake, ninja, toolchain)):
            self.skipTest('Pinned Android CMake/NDK unavailable on this host')
        fixture = Path(__file__).parent / 'android-linker'
        with tempfile.TemporaryDirectory(prefix='navi-linker-') as directory:
            build = Path(directory)
            commands = [
                [str(cmake), '-S', str(fixture), '-B', str(build), '-G', 'Ninja',
                 f'-DCMAKE_MAKE_PROGRAM={ninja.as_posix()}',
                 f'-DCMAKE_TOOLCHAIN_FILE={toolchain.as_posix()}',
                 '-DANDROID_ABI=arm64-v8a', '-DANDROID_PLATFORM=android-21',
                 '-DCMAKE_BUILD_TYPE=Release'],
                [str(cmake), '--build', str(build)],
            ]
            for command in commands:
                result = subprocess.run(command, capture_output=True, text=True, timeout=120)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for filename in ('libprobe_c.so', 'libprobe_cpp.so'):
                header = (build / filename).read_bytes()[:64]
                self.assertEqual(header[:6], b'\x7fELF\x02\x01')
                self.assertEqual(struct.unpack_from('<H', header, 18)[0], 183)
