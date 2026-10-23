"""Delivery reports must refer to the actual new packages and verified source."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).parents[1] / 'create_manifest.py'
if MODULE.exists():
    spec = importlib.util.spec_from_file_location('create_manifest', MODULE)
    manifest = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(manifest)
else:
    manifest = None
COMMIT = 'a' * 40


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.apk = self.root / 'Navi.apk'
        self.ipa = self.root / 'Navi.ipa'
        self.apk.write_bytes(b'android package')
        self.ipa.write_bytes(b'ios package')
        self.reports = [
            {'kind': 'apk', 'source_commit': COMMIT, 'artifact_sha256': hashlib.sha256(b'android package').hexdigest()},
            {'kind': 'ipa', 'source_commit': COMMIT, 'artifact_sha256': hashlib.sha256(b'ios package').hexdigest()},
        ]

    def create(self):
        self.assertIsNotNone(manifest, 'Delivery manifest has not been implemented')
        return manifest.create_manifest([self.apk, self.ipa], self.reports, COMMIT,
                                        'test-run-123', self.root / 'delivery')

    def test_rejects_missing_artifact(self):
        self.ipa.unlink()
        with self.assertRaises(ValueError):
            self.create()

    def test_rejects_hash_mismatch(self):
        self.apk.write_bytes(b'older package')
        with self.assertRaises(ValueError):
            self.create()

    def test_rejects_report_for_other_commit(self):
        self.reports[1]['source_commit'] = 'b' * 40
        with self.assertRaises(ValueError):
            self.create()

    def test_records_explicit_separate_platform_commits_without_relabeling(self):
        ios_commit = 'b' * 40
        self.reports[1]['source_commit'] = ios_commit
        sources = {'apk': COMMIT, 'ipa': ios_commit}
        path = manifest.create_manifest([self.apk, self.ipa], self.reports, COMMIT,
                                        'android-123_ios-456', self.root / 'delivery',
                                        platform_commits=sources)
        result = json.loads(path.read_text(encoding='utf-8'))
        self.assertIsNone(result['source_commit'])
        self.assertEqual(result['source_commits'], sources)
        self.assertEqual({a['kind']: a['source_commit'] for a in result['artifacts']}, sources)
        self.assertTrue(all(not a['installed_on_device'] for a in result['artifacts']))

    def test_explicit_platform_commit_still_rejects_wrong_report(self):
        with self.assertRaises(ValueError):
            manifest.create_manifest([self.apk, self.ipa], self.reports, COMMIT,
                                     'test-run', self.root / 'delivery',
                                     platform_commits={'apk': COMMIT, 'ipa': 'b' * 40})

    def test_never_infers_device_test_from_package_success(self):
        result = json.loads(self.create().read_text(encoding='utf-8'))
        for artifact in result['artifacts']:
            self.assertTrue(artifact['package_verified'])
            self.assertFalse(artifact['installed_on_device'])
            self.assertFalse(artifact['navigation_tested'])

    def test_records_each_actual_artifact_hash(self):
        result = json.loads(self.create().read_text(encoding='utf-8'))
        self.assertEqual(result['source_commit'], COMMIT)
        self.assertEqual(result['run_id'], 'test-run-123')
        hashes = {a['filename']: a['sha256'] for a in result['artifacts']}
        self.assertEqual(hashes['Navi.apk'], hashlib.sha256(b'android package').hexdigest())
        self.assertEqual(hashes['Navi.ipa'], hashlib.sha256(b'ios package').hexdigest())
        self.assertEqual((self.root/'delivery/Navi.apk').read_bytes(), b'android package')


if __name__ == '__main__':
    unittest.main()
