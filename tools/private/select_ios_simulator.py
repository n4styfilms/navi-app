"""Select a concrete available iPhone UDID from actual simctl JSON; never guess a device name."""
import json
from pathlib import Path
import re
import sys
import uuid


def select(payload):
    candidates = []
    devices = payload.get('devices', {})
    if not isinstance(devices, dict):
        raise ValueError('Malformed simulator inventory')
    for runtime, entries in devices.items():
        version = re.fullmatch(r'com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+(?:-\d+)*)', runtime)
        if not version or not isinstance(entries, list):
            continue
        for device in entries:
            if (not isinstance(device, dict) or device.get('isAvailable') is not True
                    or not str(device.get('name', '')).startswith('iPhone')):
                continue
            try:
                identity = str(uuid.UUID(device.get('udid', ''))).upper()
            except (ValueError, TypeError, AttributeError):
                continue
            candidates.append((tuple(map(int, version[1].split('-'))), device.get('state') == 'Booted',
                               identity, device, runtime))
    if not candidates:
        raise ValueError('No available iPhone simulator with a valid UDID')
    _, _, identity, device, runtime = max(candidates, key=lambda item: item[:3])
    return {'udid': identity, 'name': device['name'], 'runtime': runtime, 'state': device.get('state')}


if __name__ == '__main__':
    try:
        print(json.dumps(select(json.loads(Path(sys.argv[1]).read_text())), indent=2))
    except (ValueError, OSError, IndexError) as error:
        raise SystemExit(str(error))
