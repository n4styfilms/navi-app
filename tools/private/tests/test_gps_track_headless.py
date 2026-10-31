"""Run the actual recorder worker/storage without linking a GUI or replacing core dependencies."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class HeadlessTrackTests(unittest.TestCase):
    def test_actual_core_worker_and_storage_without_renderer(self):
        if sys.platform not in ('darwin', 'linux'):
            self.skipTest('POSIX host recorder probe runs on the free macOS host runner')
        compiler = os.environ.get('NAVI_CXX') or shutil.which('clang++') or shutil.which('g++')
        self.assertTrue(compiler, 'Actual C++ host compiler required')
        root = Path(__file__).resolve().parents[3]
        boost = root / '3party/boost'
        if not (boost / 'libs/container_hash/include/boost/container_hash/hash.hpp').is_file():
            # The host-only workflow initially checks out only the UTF-8 headers.
            # Use the repository's exact Boost gitlinks, not system/unpinned headers.
            subprocess.run(['git', '-C', str(root), 'submodule', 'update', '--init', '--depth', '1',
                '3party/boost'], check=True, capture_output=True, text=True, timeout=180)
            headers = ['assert', 'config', 'container_hash', 'core', 'describe', 'mp11',
                'static_assert', 'throw_exception', 'type_traits', 'predef']
            subprocess.run(['git', '-C', str(boost), 'submodule', 'update', '--init', '--depth', '1', '--jobs', '8',
                *('libs/' + name for name in headers)], check=True, capture_output=True, text=True, timeout=180)
        boost_includes = ['-I' + str(path) for path in sorted((boost / 'libs').glob('*/include'))]
        sources = [
            'map/gps_track.cpp', 'map/gps_track_storage.cpp', 'map/gps_track_collection.cpp',
            'map/gps_track_filter.cpp', 'map/track_statistics.cpp', 'map/elevation_info.cpp',
            'geometry/mercator.cpp', 'geometry/distance_on_sphere.cpp',
            'base/base.cpp', 'base/exception.cpp', 'base/logging.cpp', 'base/thread.cpp',
            'base/timer.cpp', 'base/src_point.cpp', 'base/internal/message.cpp',
        ]
        with tempfile.TemporaryDirectory(prefix='navi-headless-core-') as directory:
            binary = Path(directory) / 'headless-track'
            command = [compiler, '-std=c++23', '-DDEBUG', '-O0', '-pthread', '-ffunction-sections', '-fdata-sections',
                '-I' + str(root), '-I' + str(root / 'libs'), '-I' + str(root / '3party/utfcpp/source'),
                *boost_includes,
                *(str(root / 'libs' / name) for name in sources),
                str(Path(__file__).with_name('gps_track_headless_probe.cpp')),
                '-Wl,-dead_strip' if sys.platform == 'darwin' else '-Wl,--gc-sections', '-o', str(binary)]
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=180)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary), str(Path(directory) / 'raw-track.bin')],
                capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS real headless recorder progress', result.stdout)
