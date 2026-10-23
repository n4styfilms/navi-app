#!/usr/bin/env python3
"""Compile/run the actual vehicle form in a disposable SDK-only Android component host.

This intentionally does not package the navigation app or prove its Gradle/MapLibre integration.
The host requires API26+; it does not verify production minSdk21/NIO desugaring.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import uuid
import zipfile


def run(command, log, **options):
    result = subprocess.run([str(value) for value in command], capture_output=True, **options)
    output = result.stdout + result.stderr
    log.write(output)
    log.flush()
    if result.returncode:
        raise RuntimeError(f'{command[0]} failed ({result.returncode}); see build.log')
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--java-home', type=Path, required=True)
    parser.add_argument('--device', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report_path = output / 'vehicle-form-report.json'
    report_path.unlink(missing_ok=True)
    root = Path(__file__).resolve().parents[2]
    sdk = args.sdk.resolve()
    tools = sdk / 'build-tools/36.0.0'
    jar = sdk / 'platforms/android-36/android.jar'
    suffix = '.exe' if os.name == 'nt' else ''
    java = args.java_home / 'bin' / ('java' + suffix)
    adb = [sdk / 'platform-tools' / ('adb' + suffix), '-s', args.device]
    package = 'app.navi.formprobe'
    with (output / 'build.log').open('wb') as log:
        resources = root / 'android/app/src/main/res'
        compiled_resources = []
        for qualifier in ('values', 'values-de', 'values-night'):
            run([tools / ('aapt2' + suffix), 'compile', resources / qualifier / 'navi.xml', '-o', output], log)
            compiled_resources.append(output / (qualifier + '_navi.arsc.flat'))
        manifest = output / 'AndroidManifest.xml'
        manifest.write_text(f'''<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{package}">
<uses-sdk android:minSdkVersion="26" android:targetSdkVersion="36"/>
<application android:label="Navi · Formulartest" android:debuggable="true" android:allowBackup="false"
 android:theme="@android:style/Theme.Material.Light.NoActionBar">
<activity android:name="app.navi.probe.VehicleFormProbe" android:exported="true" android:windowSoftInputMode="adjustResize"/>
</application></manifest>''', encoding='utf-8')
        generated = output / 'generated'
        generated.mkdir(exist_ok=True)
        unsigned = output / 'unsigned.apk'
        run([tools / ('aapt2' + suffix), 'link', '-o', unsigned, '-I', jar, '--manifest', manifest,
             '--java', generated, '--custom-package', 'app.organicmaps', '--auto-add-overlay', *compiled_resources], log)
        classes = output / 'classes'
        classes.mkdir(exist_ok=True)
        domain = root / 'android/app/src/main/java/app/organicmaps/fuel'
        sources = [p for p in domain.glob('*.java') if p.name != 'VehicleSettingsFragment.java']
        run([args.java_home / 'bin' / ('javac' + suffix), '-encoding', 'UTF-8', '--release', '17',
             '-classpath', jar, '-d', classes, *sources, *generated.rglob('R.java'),
             root / 'tools/private/tests/VehicleFormProbe.java'], log)
        class_jar = output / 'form.jar'
        with zipfile.ZipFile(class_jar, 'w') as archive:
            for path in classes.rglob('*.class'):
                archive.write(path, path.relative_to(classes).as_posix())
        dex = output / 'dex'
        dex.mkdir(exist_ok=True)
        run([java, '-cp', tools / 'lib/d8.jar', 'com.android.tools.r8.D8', '--min-api', '26',
             '--lib', jar, '--output', dex, class_jar], log)
        with zipfile.ZipFile(unsigned, 'a') as archive:
            archive.write(dex / 'classes.dex', 'classes.dex')
        aligned = output / 'aligned.apk'
        run([tools / ('zipalign' + suffix), '-f', '4', unsigned, aligned], log)
        key = output / 'probe.jks'
        if not key.exists():
            run([args.java_home / 'bin' / ('keytool' + suffix), '-genkeypair', '-keystore', key,
                 '-storepass', 'android', '-keypass', 'android', '-alias', 'probe', '-keyalg', 'RSA',
                 '-validity', '30', '-dname', 'CN=Disposable Android Component Probe'], log)
        apk = output / 'component-probe.apk'
        run([java, '-jar', tools / 'lib/apksigner.jar', 'sign', '--ks', key, '--ks-pass', 'pass:android',
             '--key-pass', 'pass:android', '--out', apk, aligned], log)
        run([*adb, 'install', '-r', apk], log)
        reports = []
        for mode in ('exercise', 'restart'):
            identity = uuid.uuid4().hex
            run([*adb, 'shell', 'am', 'force-stop', package], log)
            run([*adb, 'shell', 'am', 'start', '-n', package + '/app.navi.probe.VehicleFormProbe',
                 '--es', 'mode', mode, '--es', 'run_id', identity], log)
            deadline = time.monotonic() + 40
            while True:
                result = subprocess.run([str(p) for p in [*adb, 'shell', 'run-as', package, 'cat',
                                        'files/probe-' + identity + '.json']], capture_output=True)
                if result.returncode == 0:
                    report = json.loads(result.stdout)
                    reports.append(report)
                    if not report['passed']:
                        raise RuntimeError(str(report))
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError('Component did not produce a result; inspect emulator/logcat')
                time.sleep(0.5)
        result = {'passed': True, 'stages': reports, 'test_package': package,
                  'probe_apk_sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
                  'source_sha256': {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                                    for p in [*sources, *(resources / q / 'navi.xml' for q in
                                                      ('values', 'values-de', 'values-night'))]},
                  'production_min_sdk_21_verified': False, 'navigation_app_installed': False}
        report_path.write_text(json.dumps(result, indent=2), encoding='utf-8')
        screenshot = subprocess.run([str(p) for p in [*adb, 'exec-out', 'screencap', '-p']],
                                    capture_output=True, check=True)
        (output / 'vehicle-form.png').write_bytes(screenshot.stdout)
        print('PASS actual Android vehicle form, validation, draft recreation, cancel, storage and process restart')


if __name__ == '__main__':
    main()
