"""Regression for false-green orchestration, using real failing child processes."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


class NativeSuiteRunnerTests(unittest.TestCase):
    def test_failure_does_not_skip_second_suite(self):
        self.check_case('failed', 'pass', False, [False, True])

    def test_zero_exit_with_failure_log_is_rejected(self):
        self.check_case('false_green', 'pass', False, [False, True])

    def test_zero_executed_cases_are_rejected(self):
        self.check_case('zero', 'pass', False, [False, True])

    def test_two_real_child_processes_must_both_pass(self):
        self.check_case('pass', 'pass', True, [True, True])

    def check_case(self, first, second, passed, expected):
        path = Path(__file__).resolve().parents[1] / 'run-native-suites.py'
        spec = importlib.util.spec_from_file_location('native_suite_runner', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix='navi-suite-runner-') as directory:
            root = Path(directory)
            child = root / 'child.py'
            child.write_text('''import sys
mode = sys.argv[1]
if '--list_tests' in sys.argv:
    print('fixture.cpp::Case')
    raise SystemExit(0)
if mode != 'zero': print('Running fixture.cpp::Case')
if mode in ('failed','false_green'):
    print('Some tests FAILED.')
    raise SystemExit(1 if mode == 'failed' else 0)
print('All tests passed.')
''',encoding='utf-8')
            report = module.run_suites({
                'map_tests': [sys.executable,str(child),first],
                'routing_tests': [sys.executable,str(child),second]}, root, [], {})
            self.assertEqual(report['passed'], passed)
            self.assertEqual([entry['passed'] for entry in report['suites']],expected)
            self.assertTrue((root/'routing_tests.log').is_file())
            self.assertEqual(report['suites'][1]['executed_cases'], 1)
