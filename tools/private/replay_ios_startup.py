#!/usr/bin/env python3
"""Debug a preserved simulator application without rebuilding the navigation core."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

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


if __name__ == '__main__':
    main()
