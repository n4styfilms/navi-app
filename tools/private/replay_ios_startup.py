#!/usr/bin/env python3
"""Debug a preserved simulator application without rebuilding the navigation core."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

from collect_ios_failure import select_app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('Simulator replay requires macOS')
    archive, out = args.archive.resolve(), args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (out / 'archive-sha256.txt').write_text(digest + '\n')
    derived = out / 'derived'
    products = derived / 'Build/Products/Debug-iphonesimulator'
    products.mkdir(parents=True)
    subprocess.run(['ditto', '-x', '-k', str(archive), str(products)], check=True, timeout=120)
    inventory = subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json'])
    inventory_file = out / 'inventory.json'
    inventory_file.write_bytes(inventory)
    selected = json.loads(subprocess.check_output([
        sys.executable, str(Path(__file__).with_name('select_ios_simulator.py')), str(inventory_file)]))
    (out / 'destination.json').write_text(json.dumps(selected, indent=2) + '\n')
    udid = selected['udid']
    subprocess.run(['xcrun', 'simctl', 'boot', udid], check=False, capture_output=True, timeout=60)
    report = {**select_app(derived), 'diagnostic_only': True, 'debugger_attached': False, 'commands': []}
    def run(command, filename, timeout=60):
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        (out / filename).write_text(result.stdout + result.stderr)
        report['commands'].append({'command': command, 'exit_code': result.returncode, 'output': filename})
        (out / 'normal-startup.json').write_text(json.dumps(report, indent=2) + '\n')
        return result
    booted = run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], 'normal-boot.txt', 180)
    if booted.returncode != 0:
        raise RuntimeError('Simulator never became ready for the original app')
    installed = run(['xcrun', 'simctl', 'install', udid, report['app']], 'normal-install.txt')
    if installed.returncode != 0:
        raise RuntimeError('Could not install preserved original app')
    # No wait-for-debugger or SIGSTOP: debugger startup itself delayed dyld and
    # its timeout could terminate the app before the later sample was taken.
    launched = run(['xcrun', 'simctl', 'launch', udid, report['bundleIdentifier']], 'normal-launch.txt')
    import re
    match = re.search(r':\s*(\d+)\s*$', launched.stdout)
    if launched.returncode != 0 or not match:
        raise RuntimeError('Normal launch did not report the original app PID')
    pid = match.group(1)
    report['pid'] = int(pid)
    time.sleep(10)
    identity = run(['ps', '-p', pid, '-o', 'comm='], 'normal-process.txt', 10)
    report['process_alive'] = identity.returncode == 0 and Path(identity.stdout.strip()).name == report['executable']
    if report['process_alive']:
        run(['/usr/bin/sample', pid, '5', '-file', str(out / 'normal-sample.txt')], 'normal-sample-command.txt', 45)
    run(['xcrun', 'simctl', 'io', udid, 'screenshot', str(out / 'normal-simulator.png')], 'normal-screenshot.txt', 30)
    time.sleep(5)
    run(['xcrun', 'simctl', 'spawn', udid, 'log', 'show', '--last', '5m', '--style', 'compact',
         '--predicate', f'process == "{report["executable"]}" OR process == "ReportCrash"'],
        'normal-system.log', 90)
    roots = [Path.home() / 'Library/Logs/DiagnosticReports',
             Path.home() / f'Library/Developer/CoreSimulator/Devices/{udid}/data/Library/Logs/CrashReporter']
    for root in roots:
        for source in root.rglob('*.ips'):
            if source.stat().st_mtime >= (out / 'archive-sha256.txt').stat().st_mtime:
                raw = source.read_text(errors='replace')
                if report['bundleIdentifier'] in raw or report['executable'] in raw:
                    (out / ('crash-' + source.stem + '.txt')).write_text(raw)
    (out / 'normal-startup.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
