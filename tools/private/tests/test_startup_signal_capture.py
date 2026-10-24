"""A diagnostic hook must retain a failing exit while writing the trapped stack."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class StartupSignalCaptureTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'Requires actual Apple signal/backtrace runtime')
    def test_trap_is_reported_and_still_fails(self):
        hook = ROOT / 'tools/private/NaviStartupCapture.c'
        with tempfile.TemporaryDirectory(prefix='navi-signal-capture-') as directory:
            main = Path(directory) / 'main.c'
            main.write_text('#include <signal.h>\nint main(void) { raise(SIGTRAP); return 0; }\n')
            binary = Path(directory) / 'capture'
            sources = [str(main), *([str(hook)] if hook.is_file() else [])]
            compiled = subprocess.run(['xcrun', 'clang', '-g', '-DNAVI_CRASH_DIAGNOSTICS_TEST=1',
                *sources, '-o', str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            trapped = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(trapped.returncode, 128 + 5, trapped.stdout + trapped.stderr)
            self.assertIn('NAVI_STARTUP_SIGNAL 5', trapped.stderr)
            self.assertIn('NAVI_STARTUP_BACKTRACE', trapped.stderr)


if __name__ == '__main__': unittest.main()
