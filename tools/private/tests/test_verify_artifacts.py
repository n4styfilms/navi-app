"""Malformed packages must never be presented as installable device builds."""
import importlib.util
import inspect
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

MODULE = Path(__file__).parents[1] / 'verify_artifacts.py'
if MODULE.exists():
    spec = importlib.util.spec_from_file_location('verify_artifacts', MODULE)
    verification = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verification)
else:
    verification = None

COMMIT = '0446bbe9d519f3024486086a038bcea9c9d7f8fd'
BADGING = """package: name='app.comaps.test' versionCode='26010101' versionName='2026.01-test'
sdkVersion:'21'
targetSdkVersion:'36'
native-code: 'arm64-v8a'
"""


def macho(platform=2, entitlements=None):
    # Mach-O platform 2 is iOS; 7 is iOS Simulator, even on ARM64.
    commands = struct.pack('<IIIIII', 0x32, 24, platform, 0x0f0000, 0x1a0000, 0)
    if entitlements:
        xml = plistlib.dumps(entitlements)
        blob = struct.pack('>II', 0xfade7171, len(xml) + 8) + xml
        signature = struct.pack('>IIIII', 0xfade0cc0, len(blob) + 20, 1, 5, 20) + blob
        commands += struct.pack('<IIII', 0x1d, 16, 72, len(signature))
    else:
        signature = b''
    header = struct.pack('<IIIIIIII', 0xfeedfacf, 0x100000c, 0, 2,
                         2 if entitlements else 1, len(commands), 0, 0)
    return header + commands + signature


def elf64():
    content = bytearray(64)
    content[:7] = b'\x7fELF\x02\x01\x01'
    struct.pack_into('<HHI', content, 16, 3, 183, 1)
    return bytes(content)


class PackageTests(unittest.TestCase):
    def test_map_apk_requires_both_renderer_and_router_for_the_only_packaged_abi(self):
        api = self.api()
        self.assertIn('require_maplibre', inspect.signature(api.verify_apk).parameters,
                      'Map delivery needs explicit device-renderer verification')
        file = self.apk()
        with self.assertRaisesRegex(ValueError, 'MapLibre'):
            api.verify_apk(file, Path('aapt2'), Path('apksigner'), require_maplibre=True)
        with zipfile.ZipFile(file, 'a') as archive:
            archive.writestr('lib/arm64-v8a/libmaplibre.so', elf64())
        with patch.object(api.subprocess, 'run', side_effect=self.tools):
            report = api.verify_apk(file, Path('aapt2'), Path('apksigner'), require_maplibre=True)
        self.assertTrue(report['maplibre_device_verified'])
        with zipfile.ZipFile(file, 'a') as archive:
            archive.writestr('lib/x86_64/libmaplibre.so', b'foreign ABI')
        with self.assertRaisesRegex(ValueError, 'ABI'):
            api.verify_apk(file, Path('aapt2'), Path('apksigner'), require_maplibre=True)

    def test_map_ipa_requires_actual_embedded_device_framework(self):
        api = self.api()
        self.assertIn('require_maplibre', inspect.signature(api.verify_ipa).parameters,
                      'Map delivery needs explicit embedded SDK verification')
        file = self.ipa()
        with self.assertRaisesRegex(ValueError, 'MapLibre'):
            api.verify_ipa(file, require_maplibre=True)
        with zipfile.ZipFile(file, 'a') as archive:
            archive.writestr('Payload/Navi0.app/Frameworks/MapLibre.framework/MapLibre', macho())
        self.assertTrue(api.verify_ipa(file, require_maplibre=True)['maplibre_device_verified'])

    def test_map_ipa_rejects_text_marker_and_simulator_sdk(self):
        api = self.api()
        for content in [b'MapLibre 6.31.0', macho(platform=7)]:
            with self.subTest(content=content[:8]):
                file = self.ipa()
                with zipfile.ZipFile(file, 'a') as archive:
                    archive.writestr('Payload/Navi0.app/Frameworks/MapLibre.framework/MapLibre', content)
                with self.assertRaises(ValueError):
                    api.verify_ipa(file, require_maplibre=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def api(self):
        self.assertIsNotNone(verification, 'Package verifier has not been implemented')
        return verification

    def apk(self, manifest=True, library=True, provenance=True):
        file = self.root / 'test.apk'
        with zipfile.ZipFile(file, 'w') as archive:
            if manifest:
                archive.writestr('AndroidManifest.xml', b'\x03\x00\x08\x00')
            if library:
                archive.writestr('lib/arm64-v8a/liborganicmaps.so', elf64())
            if provenance:
                archive.writestr('assets/private-build.json', json.dumps({'source_commit': COMMIT}))
        return file

    def ipa(self, binary=None, main_count=1, executable=True):
        file = self.root / 'test.ipa'
        with zipfile.ZipFile(file, 'w') as archive:
            for i in range(main_count):
                app = f'Payload/Navi{i}.app/'
                archive.writestr(app + 'Info.plist', plistlib.dumps({
                    'CFBundleExecutable': 'Navi', 'CFBundleIdentifier': 'app.navi.private',
                    'CFBundleVersion': '1', 'NaviSourceCommit': COMMIT,
                    'CFBundleSupportedPlatforms': ['iPhoneOS'],
                }))
                if executable:
                    archive.writestr(app + 'Navi', binary if binary is not None else macho())
        return file

    def tools(self, command, **kwargs):
        if 'badging' in command:
            return subprocess.CompletedProcess(command, 0, BADGING, '')
        return subprocess.CompletedProcess(command, 0, 'Verifies\nVerified using v2 scheme: true', '')

    def test_rejects_non_zip(self):
        api = self.api()
        file = self.root / 'bad.apk'
        file.write_bytes(b'not a zip')
        with self.assertRaises(ValueError):
            api.verify_apk(file, Path('aapt2'), Path('apksigner'))

    def test_rejects_missing_android_manifest(self):
        api = self.api()
        with self.assertRaisesRegex(ValueError, 'manifest'):
            api.verify_apk(self.apk(manifest=False), Path('aapt2'), Path('apksigner'))

    def test_rejects_missing_arm64_library(self):
        api = self.api()
        with self.assertRaisesRegex(ValueError, 'ARM64'):
            api.verify_apk(self.apk(library=False), Path('aapt2'), Path('apksigner'))

    def test_rejects_missing_build_provenance(self):
        api = self.api()
        with self.assertRaisesRegex(ValueError, 'provenance'):
            api.verify_apk(self.apk(provenance=False), Path('aapt2'), Path('apksigner'))

    def test_propagates_apksigner_failure(self):
        api = self.api()
        def external(command, **kwargs):
            if 'verify' in command:
                raise subprocess.CalledProcessError(1, command, stderr='signature invalid')
            return self.tools(command, **kwargs)
        with patch.object(api.subprocess, 'run', side_effect=external):
            with self.assertRaises(ValueError):
                api.verify_apk(self.apk(), Path('aapt2'), Path('apksigner'))

    def test_reports_aapt_badging_fields(self):
        api = self.api()
        with patch.object(api.subprocess, 'run', side_effect=self.tools):
            report = api.verify_apk(self.apk(), Path('aapt2'), Path('apksigner'))
        self.assertEqual(report['application_id'], 'app.comaps.test')
        self.assertEqual(report['version_code'], '26010101')
        self.assertEqual(report['abis'], ['arm64-v8a'])
        self.assertTrue(report['signature_verified'])
        self.assertEqual(report['source_commit'], COMMIT)

    def test_rejects_missing_payload_app(self):
        api = self.api()
        with self.assertRaisesRegex(ValueError, 'main app'):
            api.verify_ipa(self.ipa(main_count=0))

    def test_rejects_multiple_main_apps(self):
        api = self.api()
        with self.assertRaisesRegex(ValueError, 'main app'):
            api.verify_ipa(self.ipa(main_count=2))

    def test_rejects_missing_executable(self):
        api = self.api()
        with self.assertRaisesRegex(ValueError, 'executable'):
            api.verify_ipa(self.ipa(executable=False))

    def test_rejects_simulator_platform_even_on_arm64(self):
        api = self.api()
        with self.assertRaisesRegex(ValueError, 'iOS device'):
            api.verify_ipa(self.ipa(binary=macho(platform=7)))

    def test_rejects_macos_platform_even_on_arm64(self):
        api = self.api()
        with self.assertRaisesRegex(ValueError, 'iOS device'):
            api.verify_ipa(self.ipa(binary=macho(platform=1)))

    def test_rejects_restricted_entitlements(self):
        api = self.api()
        with self.assertRaisesRegex(ValueError, 'entitlement'):
            api.verify_ipa(self.ipa(binary=macho(entitlements={'com.apple.developer.carplay-maps': True})))

    def test_rejects_simulator_framework(self):
        api = self.api()
        file = self.ipa()
        with zipfile.ZipFile(file, 'a') as archive:
            archive.writestr('Payload/Navi0.app/Frameworks/Map.framework/Map', macho(platform=7))
        with self.assertRaisesRegex(ValueError, 'iOS device'):
            api.verify_ipa(file)

    def test_accepts_unsigned_ios_arm64_bundle(self):
        api = self.api()
        report = api.verify_ipa(self.ipa())
        self.assertEqual(report['platform'], 'iOS')
        self.assertEqual(report['architectures'], ['arm64'])
        self.assertEqual(report['bundle_id'], 'app.navi.private')
        self.assertEqual(report['source_commit'], COMMIT)
        self.assertEqual(report['restricted_entitlements'], [])


if __name__ == '__main__':
    unittest.main()
