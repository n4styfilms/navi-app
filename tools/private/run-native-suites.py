"""Run both native suites and reject failed, missing or zero-case results."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


def run_suites(commands, out, arguments, required_markers):
    out.mkdir(parents=True, exist_ok=True)
    suites = []
    for name, command in commands.items():
        entry = {"name": name, "passed": False, "registered_cases": 0, "executed_cases": 0}
        try:
            listing = subprocess.run([*command, '--list_tests'], capture_output=True,
                                     text=True, encoding='utf-8', errors='replace', timeout=60)
            (out / (name + '.list')).write_text(listing.stdout + listing.stderr, encoding='utf-8')
            entry['registered_cases'] = len(re.findall(r'^\S+::\S+\s*$', listing.stdout, re.MULTILINE))
            result = subprocess.run([*command, *arguments], capture_output=True,
                                    text=True, encoding='utf-8', errors='replace', timeout=1200)
            text = result.stdout + result.stderr
            (out / (name + '.log')).write_text(text, encoding='utf-8')
            entry['returncode'] = result.returncode
            entry['executed_cases'] = len(re.findall(r'^Running .+$', text, re.MULTILINE))
            entry['passed'] = (listing.returncode == 0 and result.returncode == 0 and
                entry['registered_cases'] > 0 and entry['executed_cases'] == entry['registered_cases'] and
                'All tests passed.' in text and 'Some tests FAILED.' not in text and
                all(marker in text for marker in required_markers.get(name, [])))
            executable = Path(command[0])
            if executable.is_file():
                entry['binary_sha256'] = hashlib.sha256(executable.read_bytes()).hexdigest()
        except (OSError, subprocess.TimeoutExpired) as error:
            entry['error'] = str(error)
        suites.append(entry)
        print(f"{name}: {'PASS' if entry['passed'] else 'FAIL'} "
              f"({entry['executed_cases']}/{entry['registered_cases']} cases)", flush=True)
    return {'passed': bool(suites) and all(entry['passed'] for entry in suites), 'suites': suites}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build', type=Path)
    parser.add_argument('data', type=Path)
    parser.add_argument('resources', type=Path)
    args = parser.parse_args()
    build = args.build.resolve()
    report = run_suites({name: [str(build/name)] for name in ('map_tests','routing_tests')}, build,
        ['--data_path='+str(args.data.resolve()), '--user_resource_path='+str(args.resources.resolve())],
        {'map_tests': ['NaviHeadless_RealMapNavigationReplay',
            'PASS real-map headless navigation, GPS, TTS, reroute, cancellation and failure',
            'PASS failed reroute keeps old navigation']})
    report['tested_at_utc'] = datetime.now(timezone.utc).isoformat()
    report['app_installed'] = False
    (build/'native-test-report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    if not report['passed']:
        print('FAIL native suites; inspect per-suite logs', file=sys.stderr)
        return 1
    print('PASS native map_tests and routing_tests, including real-map headless replay')
    return 0


if __name__ == '__main__':
    sys.exit(main())
