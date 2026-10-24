#!/usr/bin/env python3
"""Collect an actual simulator startup stack after a failed full-app test.

Diagnostics never change the original xcodebuild result. No replacement app,
test doubles, certificate changes or alternate renderer are introduced here.
"""
import argparse
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import threading


def select_app(derived):
    found = []
    for app in Path(derived).glob('Build/Products/*iphonesimulator/*.app'):
        info_file = app / 'Info.plist'
        if not info_file.is_file():
            continue
        info = plistlib.loads(info_file.read_bytes())
        if info.get('CFBundleIdentifier') == 'app.navi.private':
            executable = info.get('CFBundleExecutable', '')
            if not executable or Path(executable).name != executable or not (app / executable).is_file():
                raise ValueError('Selected application has no valid built executable')
            found.append({'app': str(app.resolve()), 'bundleIdentifier': 'app.navi.private',
                          'executable': executable})
    if len(found) != 1:
        raise ValueError(f'Expected exactly one built app.navi.private application; found {len(found)}')
    return found[0]


def collect(out, derived, udid, archive_app=True):
    out.mkdir(parents=True, exist_ok=True)
    report = {'diagnostic_only': True, 'original_test_result_preserved': True, 'commands': []}
    def run(args, filename, timeout=60):
        record = {'command': args, 'output': filename}
        try:
            result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
            data = result.stdout
            record['exit_code'] = result.returncode
        except subprocess.TimeoutExpired as error:
            data = error.stdout or b''
            record['timed_out'] = True
        (out / filename).write_bytes(data)
        report['commands'].append(record)
        (out / 'startup-diagnostic.json').write_text(json.dumps(report, indent=2) + '\n')
        return data, record

    selected = select_app(derived)
    report.update(selected)
    run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], 'startup-boot.txt', 90)
    run(['xcrun', 'simctl', 'terminate', udid, selected['bundleIdentifier']], 'startup-terminate.txt')
    _, installed = run(['xcrun', 'simctl', 'install', udid, selected['app']], 'startup-install.txt')
    if installed.get('exit_code') != 0:
        raise RuntimeError('Could not install the actual built simulator application')
    launched, _ = run(['xcrun', 'simctl', 'launch', '--wait-for-debugger', udid,
                      selected['bundleIdentifier']], 'startup-launch.txt')
    match = re.search(rb':\s*(\d+)\s*$', launched)
    if not match:
        raise RuntimeError('Simulator did not report the launched application PID')
    pid = match.group(1).decode('ascii')
    report['pid'] = int(pid)
    # LLDB batch mode skips ordinary subsequent commands when the process crashes.
    # Its on-crash commands are required to retain the actual trapping stack.
    # A blocked main thread does not trigger LLDB's on-crash commands. Sample
    # that case with an explicitly recorded diagnostic SIGSTOP, not a fake crash.
    stopped = {}
    def interrupt_owned_process():
        identity = subprocess.run(['ps', '-p', pid, '-o', 'comm='], capture_output=True, text=True, timeout=10)
        if identity.returncode != 0 or Path(identity.stdout.strip()).name != selected['executable']:
            stopped['skipped'] = 'PID no longer identifies the expected application'
            return
        result = subprocess.run(['/bin/kill', '-STOP', pid], capture_output=True, timeout=10)
        stopped['exit_code'] = result.returncode
        (out / 'startup-deliberate-stop.txt').write_bytes(result.stdout + result.stderr)
    timer = threading.Timer(25, interrupt_owned_process)
    timer.daemon = True
    timer.start()
    try:
        run(['xcrun', 'lldb', '--batch', '-p', pid,
             '--one-line', 'process handle SIGPIPE -n false -p true -s false',
             '--one-line', 'continue',
             '--one-line', 'thread backtrace all',
             '--one-line', 'image list',
             '--one-line', 'process detach',
             '--one-line-on-crash', 'thread backtrace all',
             '--one-line-on-crash', 'image list'], 'startup-debugger.txt', 90)
    finally:
        timer.cancel()
        timer.join(timeout=12)
    report['deliberate_diagnostic_stop'] = stopped
    run(['xcrun', 'simctl', 'io', udid, 'screenshot', str(out / 'startup-simulator.png')],
        'startup-screenshot.txt')
    process = selected['executable'].replace('\\', '\\\\').replace('"', '\\"')
    run(['xcrun', 'simctl', 'spawn', udid, 'log', 'show', '--last', '3m', '--style', 'compact',
         '--predicate', f'process == "{process}" OR process == "ReportCrash"'],
        'startup-system.log', 90)
    # Retain the same binary for later diagnosis without another C++ rebuild,
    # bounded to avoid large optional debug archives consuming artifact storage.
    app = Path(selected['app'])
    app_bytes = sum(p.stat().st_size for p in app.rglob('*') if p.is_file())
    report['application_bytes'] = app_bytes
    if archive_app and app_bytes <= 500_000_000:
        archive = Path(derived).resolve() / 'startup-simulator-app.zip'
        _, archived = run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)],
                          'startup-archive.txt', 180)
        if archived.get('exit_code') == 0 and archive.stat().st_size <= 150_000_000:
            shutil.copyfile(archive, out / 'startup-simulator-app.zip')
            report['application_archive_bytes'] = archive.stat().st_size
    (out / 'startup-diagnostic.json').write_text(json.dumps(report, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--select-app', type=Path, help='Only validate and print the built application selection')
    parser.add_argument('--out', type=Path)
    parser.add_argument('--derived', type=Path)
    parser.add_argument('--udid')
    args = parser.parse_args()
    try:
        if args.select_app:
            print(json.dumps(select_app(args.select_app)))
            return
        if not args.out or not args.derived or not args.udid:
            parser.error('--out, --derived and --udid are required for simulator collection')
        if sys.platform != 'darwin':
            parser.error('Actual simulator collection requires the macOS build runner')
        collect(args.out.resolve(), args.derived.resolve(), args.udid)
    except (ValueError, OSError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)


if __name__ == '__main__':
    main()
