import importlib.util
from pathlib import Path
import unittest

PATH = Path(__file__).parents[1] / 'select_ios_simulator.py'
selection = None
if PATH.exists():
    spec = importlib.util.spec_from_file_location('select_ios_simulator', PATH)
    selection = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(selection)


class IosSimulatorSelectionTests(unittest.TestCase):
    def test_chooses_real_available_iphone_on_latest_runtime(self):
        self.assertIsNotNone(selection, 'No concrete simctl destination selector')
        old = '11111111-1111-1111-1111-111111111111'
        current = '22222222-2222-2222-2222-222222222222'
        result = selection.select({'devices': {
            'com.apple.CoreSimulator.SimRuntime.iOS-18-6': [
                {'name': 'iPhone older', 'udid': old, 'isAvailable': True, 'state': 'Booted'}],
            'com.apple.CoreSimulator.SimRuntime.iOS-26-1': [
                {'name': 'iPhone unavailable', 'udid': old, 'isAvailable': False},
                {'name': 'iPad', 'udid': old, 'isAvailable': True},
                {'name': 'iPhone current', 'udid': current, 'isAvailable': True, 'state': 'Shutdown'}],
            'com.apple.CoreSimulator.SimRuntime.tvOS-27-0': [
                {'name': 'iPhone wrong platform', 'udid': old, 'isAvailable': True}]}})
        self.assertEqual(result['udid'], current)
        self.assertEqual(result['runtime'], 'com.apple.CoreSimulator.SimRuntime.iOS-26-1')
        self.assertEqual(result['name'], 'iPhone current')

    def test_missing_unavailable_or_invalid_destination_fails(self):
        self.assertIsNotNone(selection, 'No concrete simctl destination selector')
        for payload in [{}, {'devices': {}}, {'devices': {
            'com.apple.CoreSimulator.SimRuntime.iOS-26-1': [
                {'name': 'iPhone invalid', 'udid': 'invented', 'isAvailable': True}]}}]:
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                selection.select(payload)
