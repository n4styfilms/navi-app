import importlib.util
import json
from pathlib import Path
import unittest


class AppleProofResultTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('apple_proof_result',
            Path(__file__).resolve().parents[1] / 'apple_proof_result.py')
        cls.reader = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.reader)

    def setUp(self):
        self.specification = {'cases': ['native_apple_a', 'native_apple_b'], 'extra': ['native_apple_bridge']}
        self.result = {'nonce': 'fresh', 'source': 'exact-source', 'status': 'passed',
            'proofs': ['native_apple_bridge', 'native_apple_b', 'native_apple_a']}

    def read(self, result):
        return self.reader.validate_result(json.dumps(result).encode(), 'fresh', 'exact-source', self.specification)

    def test_accepts_only_complete_current_result(self):
        self.assertEqual(self.read(self.result), ['native_apple_a', 'native_apple_b', 'native_apple_bridge'])

    def test_rejects_stale_wrong_source_failed_partial_and_duplicate_results(self):
        for key, value in [('nonce', 'previous'), ('source', 'different-source'), ('status', 'failed'),
            ('proofs', ['native_apple_a']), ('proofs', self.result['proofs'] + ['native_apple_a']),
            ('proofs', self.result['proofs'] + ['native_apple_unexpected']), ('proofs', [True, False]),
            ('proofs', 'native_apple_a')]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                self.read(dict(self.result, **{key: value}))

    def test_rejects_missing_malformed_or_oversized_data(self):
        for payload in [b'', b'[]', b'{broken', b'{}', b' ' * 65537]:
            with self.subTest(payload=payload[:20]), self.assertRaises(ValueError):
                self.reader.validate_result(payload, 'fresh', 'exact-source', self.specification)
