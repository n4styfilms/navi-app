#!/usr/bin/env python3
"""Decode an existing CI XCTest result; never rebuild or alter the original test verdict."""
import argparse
import json
import re
from pathlib import Path
import subprocess
import sys
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('Apple xcresulttool requires the macOS diagnostic runner')
    bundle, out = args.bundle.resolve(), args.output.resolve()
    if not (bundle / 'Info.plist').is_file():
        parser.error('The captured XCTest result bundle is missing')
    out.mkdir(parents=True, exist_ok=False)
    # Symbolicate the exact preserved binary, rather than rebuilding a possibly
    # different executable. The simulator capture prints both PC and image base.
    archive = bundle.parent / 'startup-simulator-app.zip'
    startup_log = bundle.parent / 'xcode-tests.log'
    if archive.is_file() and startup_log.is_file():
        text = startup_log.read_text(errors='replace')
        pc = re.search(r'NAVI_STARTUP_PC (0x[0-9a-fA-F]+)', text)
        base = re.search(r'NAVI_STARTUP_IMAGE_BASE (0x[0-9a-fA-F]+)', text)
        if pc and base:
            images = out / 'symbolication'
            subprocess.run(['ditto', '-x', '-k', str(archive), str(images)], check=True, timeout=120)
            binaries = list(images.rglob('*.debug.dylib'))
            if len(binaries) != 1:
                raise RuntimeError('Expected one preserved app debug image')
            binary = binaries[0]
            offset = int(pc[1], 16) - int(base[1], 16)
            commands = ['target create ' + json.dumps(str(binary)), 'image list -o -f',
                        f'image lookup -v -a {hex(offset)}',
                        f'disassemble -s {hex(offset - 160)} -c 64']
            command_file = out / 'symbolication-commands.txt'
            command_file.write_text('\n'.join(commands) + '\n')
            symbols = subprocess.run(['xcrun', 'lldb', '-b', '-s', str(command_file)],
                                     capture_output=True, timeout=90)
            (out / 'symbolication.txt').write_bytes(symbols.stdout + symbols.stderr)
    records = []
    def run(arguments, filename, timeout=90):
        result = subprocess.run(['xcrun', 'xcresulttool', *arguments], capture_output=True, timeout=timeout)
        (out / filename).write_bytes(result.stdout[:10_000_000])
        if result.stderr:
            (out / (filename + '.stderr.txt')).write_bytes(result.stderr[:1_000_000])
        records.append({'arguments': arguments, 'exit_code': result.returncode, 'output': filename})
        return result
    run(['get', 'test-results', 'summary', '--path', str(bundle)], 'xcresult-summary.json')
    run(['get', 'object', '--legacy', '--path', str(bundle), '--format', 'json'], 'xcresult-root.json')
    run(['get', 'log', '--type', 'action', '--path', str(bundle)], 'xcresult-action.log')
    exported = out / 'diagnostic-tree'
    result = run(['export', 'diagnostics', '--path', str(bundle), '--output-path', str(exported)],
                 'xcresult-export.txt', 180)
    index, kept = [], []
    total = 0
    def retain(name, data):
        nonlocal total
        name_lower = name.lower()
        if not (name_lower.endswith(('.ips', '.crash')) or 'standardoutputandstandarderror' in name_lower
                or 'session-comaps' in name_lower or name_lower.endswith('/testmanagerd.log')):
            return
        if b'app.navi.private' not in data and b'CoMaps' not in data and 'comaps' not in name_lower:
            return
        if total + len(data) > 25_000_000:
            return
        target = f'xcresult-captured-{len(kept):03d}.txt'
        (out / target).write_bytes(data)
        kept.append({'source': name, 'output': target, 'bytes': len(data)})
        total += len(data)
    for file in sorted(exported.rglob('*')):
        if not file.is_file():
            continue
        relative = str(file.relative_to(exported))
        index.append({'path': relative, 'bytes': file.stat().st_size})
        if zipfile.is_zipfile(file):
            with zipfile.ZipFile(file) as archive:
                for entry in archive.infolist():
                    if entry.is_dir(): continue
                    index.append({'archive': relative, 'member': entry.filename, 'bytes': entry.file_size})
                    if entry.file_size <= 6_000_000:
                        with archive.open(entry) as stream:
                            retain(relative + '/' + entry.filename, stream.read(6_000_001))
        elif file.stat().st_size <= 6_000_000:
            retain(relative, file.read_bytes())
    for count, archive in enumerate(exported.rglob('*.logarchive')):
        captured = subprocess.run(['/usr/bin/log', 'show', '--archive', str(archive), '--style', 'compact',
            '--info', '--debug', '--predicate',
            'process == "CoMaps (Debug)" OR process == "ReportCrash" OR process == "testmanagerd" '
            'OR eventMessage CONTAINS "app.navi.private" OR eventMessage CONTAINS "CoMaps"'],
            capture_output=True, timeout=120)
        filename = f'xcresult-archived-system-{count}.log'
        (out / filename).write_bytes((captured.stdout + captured.stderr)[:10_000_000])
        records.append({'archive': str(archive), 'exit_code': captured.returncode, 'output': filename})
    report = {'diagnostic_only': True, 'original_test_verdict_unchanged': True,
              'bundle': str(bundle), 'commands': records, 'retained': kept, 'export_inventory': index}
    (out / 'xcresult-export.json').write_text(json.dumps(report, indent=2) + '\n')
    if result.returncode != 0:
        raise SystemExit('xcresulttool could not export the captured test diagnostics')
    print(json.dumps({'captured_app_reports': len(kept), 'retained_bytes': total}))


if __name__ == '__main__':
    main()
