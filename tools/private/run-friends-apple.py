"""Launch only the synthetic friends fixture on an existing CI iPhone simulator."""
import json
from pathlib import Path
import subprocess
import sys
import shutil
import time
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
evidence = out.parent / 'friends-evidence'
evidence.mkdir(exist_ok=True)
shutil.copyfile(out / 'simulator.json', evidence / 'native-simulator.json')
started = time.time()
passed = False
try:
    result = subprocess.run(['xcrun', 'simctl', 'launch', '--terminate-running-process', '--console', udid,
                             'app.navi.friendstest'], capture_output=True, timeout=75)
    transcript = result.stdout + result.stderr
    (out / 'simulator-runtime.log').write_bytes(transcript)
    (evidence / 'native-launch-console.log').write_bytes(transcript)
    (evidence / 'native-launch.json').write_text(json.dumps({'returncode': result.returncode,
        'elapsed_seconds': time.time() - started}, indent=2))
    sys.stdout.buffer.write(transcript)
    container = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', udid,
        'app.navi.friendstest', 'data'], text=True, timeout=15).strip()
    for name in ['friends-ui-light.png', 'friends-ui-dark-large.png']:
        screenshot = Path(container) / 'Documents' / name
        if screenshot.is_file():
            shutil.copyfile(screenshot, evidence / name)
    if result.returncode != 0 or b'NAVI_APPLE_NATIVE_ERROR' in transcript or b'NAVI_APPLE_NATIVE_SUCCESS proofs=15' not in transcript:
        raise SystemExit('Simulator native friends fixture did not pass')
    passed = True
except subprocess.TimeoutExpired as error:
    (evidence / 'native-launch-console.log').write_bytes((error.stdout or b'') + (error.stderr or b''))
    (evidence / 'native-launch.json').write_text(json.dumps({'timed_out': True,
        'elapsed_seconds': time.time() - started}, indent=2))
    raise
finally:
    if not passed:
        # Read only this synthetic fixture's diagnostics. Do not relaunch it: a
        # second attempt could reuse SDK Keychain state and hide the first fault.
        try:
            logged = subprocess.run(['xcrun', 'simctl', 'spawn', udid, 'log', 'show', '--last', '5m',
                '--style', 'compact', '--predicate', 'process == "FriendsNativeProbe"'],
                capture_output=True, timeout=30)
            (evidence / 'native-simulator-log.txt').write_bytes(logged.stdout + logged.stderr)
            roots = [Path.home() / 'Library/Logs/DiagnosticReports',
                Path.home() / 'Library/Developer/CoreSimulator/Devices' / udid / 'data/Library/Logs/CrashReporter']
            for index, directory in enumerate(roots):
                for crash in directory.glob('FriendsNativeProbe*.ips'):
                    if crash.is_file() and crash.stat().st_mtime >= started - 10:
                        shutil.copyfile(crash, evidence / (str(index) + '-' + crash.name))
        except Exception as error:
            (evidence / 'native-diagnostic-error.txt').write_text(str(error))
    subprocess.run(['xcrun', 'simctl', 'terminate', udid, 'app.navi.friendstest'], capture_output=True, timeout=30)
