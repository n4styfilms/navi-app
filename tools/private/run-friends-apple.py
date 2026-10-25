"""Launch only the synthetic friends fixture on an existing CI iPhone simulator."""
import json
from pathlib import Path
import subprocess
import sys
from select_ios_simulator import select

out = Path(sys.argv[1]).resolve()
inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
device = select(inventory)
(out / 'simulator.json').write_text(json.dumps(device, indent=2), encoding='utf-8')
udid = device['udid']
if device['state'] != 'Booted':
    subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True, timeout=60)
subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True, timeout=180)
app = out / 'DerivedData/Build/Products/Debug-iphonesimulator/FriendsNativeProbe.app'
subprocess.run(['xcrun', 'simctl', 'install', udid, str(app)], check=True, timeout=60)
try:
    result = subprocess.run(['xcrun', 'simctl', 'launch', '--terminate-running-process', '--console', udid,
                             'app.navi.friendstest'], capture_output=True, timeout=75)
    transcript = result.stdout + result.stderr
    (out / 'simulator-runtime.log').write_bytes(transcript)
    sys.stdout.buffer.write(transcript)
    if result.returncode != 0 or b'NAVI_APPLE_NATIVE_ERROR' in transcript or b'NAVI_APPLE_NATIVE_SUCCESS proofs=10' not in transcript:
        raise SystemExit('Simulator native friends fixture did not pass')
finally:
    subprocess.run(['xcrun', 'simctl', 'terminate', udid, 'app.navi.friendstest'], capture_output=True, timeout=30)
