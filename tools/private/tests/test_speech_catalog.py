"""Compile the production voice-discovery boundary with an intentionally blocked provider."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class SpeechCatalogTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'Requires actual Apple Foundation/AVFoundation')
    def test_blocked_voice_discovery_keeps_main_loop_responsive(self):
        source = ROOT / 'iphone/Maps/Core/TextToSpeech'
        probe = Path(__file__).with_name('SpeechCatalogProbe.mm')
        with tempfile.TemporaryDirectory(prefix='navi-speech-catalog-') as directory:
            binary = Path(directory) / 'speech-catalog'
            built = subprocess.run(['xcrun', 'clang++', '-std=c++20', '-fobjc-arc', '-fblocks',
                '-framework', 'Foundation', '-framework', 'AVFoundation', '-I', str(source),
                str(source / 'MWMSpeechVoiceCatalog.mm'), str(probe), '-o', str(binary)],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=12)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for flag in ['speech_catalog_main_responsive', 'speech_catalog_provider_once',
                         'speech_catalog_completions_main']:
                self.assertIn(flag + '=true', result.stdout)


if __name__ == '__main__': unittest.main()
