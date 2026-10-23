"""Build the real route adapter with the pinned NDK and run its cases through ADB.

This does not build/install the app or claim real-map routing/navigation coverage.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', required=True, type=Path)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--abi', choices=['x86_64', 'arm64-v8a'], default='x86_64')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    sdk = args.sdk.resolve()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    suffix = '.exe' if (sdk / 'platform-tools/adb.exe').is_file() else ''
    cmake = sdk / ('cmake/3.22.1/bin/cmake' + suffix)
    ninja = sdk / ('cmake/3.22.1/bin/ninja' + suffix)
    adb = sdk / ('platform-tools/adb' + suffix)
    toolchain = sdk / 'ndk/28.2.13676358/build/cmake/android.toolchain.cmake'
    for required in (cmake, ninja, adb, toolchain):
        if not required.is_file():
            parser.error(f'Required tool unavailable: {required}')
    build = out / ('build-' + args.abi)
    log = out / 'capture-build.log'

    def run(command, timeout=180):
        result = subprocess.run([str(arg) for arg in command], capture_output=True,
                                text=True, timeout=timeout)
        with log.open('a', encoding='utf-8') as stream:
            stream.write(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError((result.stdout + result.stderr)[-6000:])
        return result.stdout.strip()

    state = run([adb, '-s', args.serial, 'get-state'], 15)
    if state != 'device':
        raise RuntimeError('Selected Android device is not ready')
    run([cmake, '-S', root / 'tools/private/tests/capture-build', '-B', build, '-G', 'Ninja',
         '-DCMAKE_MAKE_PROGRAM=' + ninja.as_posix(),
         '-DCMAKE_TOOLCHAIN_FILE=' + toolchain.as_posix(),
         '-DANDROID_ABI=' + args.abi, '-DANDROID_PLATFORM=android-26',
         '-DANDROID_STL=c++_static', '-DCMAKE_BUILD_TYPE=Release'])
    run([cmake, '--build', build, '--parallel', '2'], 300)
    executable = build / 'capture_tests'
    remote = '/data/local/tmp/navi-private-tests/capture_tests'
    run([adb, '-s', args.serial, 'shell', 'mkdir', '-p', '/data/local/tmp/navi-private-tests'], 15)
    run([adb, '-s', args.serial, 'push', executable, remote], 30)
    run([adb, '-s', args.serial, 'shell', 'chmod', '700', remote], 15)
    result = run([adb, '-s', args.serial, 'shell', remote], 30)
    if result != 'PASS 6 real route capture cases':
        raise RuntimeError('No complete capture test result: ' + result)
    sources = ['libs/map/navi_route_capture.cpp', 'libs/map/map_tests/navi_route_snapshot_tests.cpp',
               'tools/private/tests/navi_capture_test.cpp']
    report = {
        'result': result, 'abi': args.abi,
        'device_api': run([adb, '-s', args.serial, 'shell', 'getprop', 'ro.build.version.sdk'], 15),
        'binary_sha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
        'source_sha256': {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in sources},
        'uses_real_core_route_classes': True,
        'downloaded_map_routing_tested': False, 'app_installed': False, 'navigation_tested': False,
    }
    (out / 'capture-report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(result)
    print('Report:', out / 'capture-report.json')


if __name__ == '__main__':
    main()
