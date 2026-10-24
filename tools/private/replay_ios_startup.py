#!/usr/bin/env python3
"""Debug a preserved simulator application without rebuilding the navigation core."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

from collect_ios_failure import collect


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
    collect(out, derived, udid, archive_app=False)
    # Let the detached app finish loading before inspecting it again. The first
    # diagnostic stop can land in dyld while LLDB loads this large binary.
    time.sleep(15)
    report = json.loads((out / 'startup-diagnostic.json').read_text())
    pid = str(report['pid'])
    identity = subprocess.run(['ps', '-p', pid, '-o', 'comm='], capture_output=True, text=True, timeout=10)
    (out / 'post-detach-process.txt').write_text(identity.stdout + identity.stderr)
    if identity.returncode == 0 and Path(identity.stdout.strip()).name == report['executable']:
        sampled = subprocess.run(['/usr/bin/sample', pid, '5', '-file', str(out / 'post-detach-sample.txt')],
                                 capture_output=True, text=True, timeout=45)
        (out / 'post-detach-sample-command.txt').write_text(sampled.stdout + sampled.stderr)
        subprocess.run(['xcrun', 'simctl', 'io', udid, 'screenshot', str(out / 'post-detach-simulator.png')],
                       capture_output=True, timeout=30)
    # Keep genuine crash reports, if startup ended after detaching the debugger.
    reports = Path.home() / 'Library/Logs/DiagnosticReports'
    for source in reports.glob('*.ips'):
        if source.stat().st_mtime >= (out / 'archive-sha256.txt').stat().st_mtime:
            raw = source.read_text(errors='replace')
            if report['bundleIdentifier'] in raw or report['executable'] in raw:
                (out / ('crash-' + source.stem + '.txt')).write_text(raw)


if __name__ == '__main__':
    main()
