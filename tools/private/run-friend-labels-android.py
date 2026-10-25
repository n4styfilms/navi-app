"""Run the real MapLibre friend-label regression on an explicitly named disposable AVD.

Requires JDK/Android SDK, Gradle 8.14+, and the public Noto glyph fixture below.
No Firebase configuration, user data, trust overrides, or main-app installation.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time

GLYPH_SHA = 'ef1f38a3f1978591e846e9eaddf8a54f7047f546fc6aaed7872cc53151a5de78'
GLYPH_URL = 'https://tiles.openfreemap.org/fonts/Noto%20Sans%20Regular/0-255.pbf'
PACKAGE = 'app.navi.mapprobe'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--gradle', required=True)
    parser.add_argument('--adb', required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--avd', required=True)
    parser.add_argument('--glyph', required=True, type=Path, help=GLYPH_URL)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--maven-directory', action='append', default=[], type=Path)
    args = parser.parse_args()
    if not args.serial.startswith('emulator-'):
        raise SystemExit('Only a named Android emulator is allowed')
    adb = [args.adb, '-s', args.serial]
    result = subprocess.run(adb + ['emu', 'avd', 'name'], capture_output=True, text=True, timeout=15, check=True)
    if result.stdout.splitlines()[0].strip() != args.avd:
        raise SystemExit('AVD name mismatch')
    glyph = args.glyph.read_bytes()
    if hashlib.sha256(glyph).hexdigest() != GLYPH_SHA:
        raise SystemExit('Public glyph fixture checksum mismatch')
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[2]
    java = out / 'src/main/java'
    records = []
    for prefix, sources in [
        ('android/app/src/main/java', list((root / 'android/app/src/main/java/app/organicmaps/navi/map').glob('*.java'))),
        ('android/sdk/src/main/java', [root / 'android/sdk/src/main/java/app/organicmaps/sdk/routing/NaviRouteSnapshot.java'])
    ]:
        for source in sources:
            target = java / source.relative_to(root / prefix)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            records.append({'source': source.relative_to(root).as_posix(), 'sha256': hashlib.sha256(source.read_bytes()).hexdigest()})
    activity = java / 'app/navi/mapprobe/FriendLabelsActivity.java'
    activity.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(Path(__file__).with_name('tests') / activity.name, activity)
    assets = out / 'src/main/assets'
    assets.mkdir()
    (assets / 'noto-0-255.pbf').write_bytes(glyph)
    (out / 'source-copies.json').write_text(json.dumps(records, indent=2), encoding='utf-8')
    repositories = ''.join('maven { url = uri(' + json.dumps(str(p.resolve()).replace('\\', '/')) + ') }; ' for p in args.maven_directory)
    (out / 'settings.gradle').write_text("pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }\n"
        + 'dependencyResolutionManagement { repositories { ' + repositories + 'google(); mavenCentral() } }\n'
        + 'rootProject.name="NaviFriendLabelsProbe"\n', encoding='utf-8')
    (out / 'gradle.properties').write_text('android.useAndroidX=true\norg.gradle.jvmargs=-Xmx3072m\n', encoding='utf-8')
    (out / 'build.gradle').write_text("""plugins { id 'com.android.application' version '8.11.1' }
android {
 namespace 'app.navi.mapprobe'
 compileSdk 36
 defaultConfig { applicationId 'app.navi.mapprobe'; minSdk 23; targetSdk 36; versionCode 1; versionName 'probe'; ndk { abiFilters 'x86_64' } }
 compileOptions { sourceCompatibility JavaVersion.VERSION_17; targetCompatibility JavaVersion.VERSION_17 }
}
dependencies {
 implementation 'org.maplibre.gl:android-sdk-opengl:13.7.1'
 implementation 'com.squareup.okhttp3:okhttp:4.12.0'
 implementation 'androidx.appcompat:appcompat:1.7.1'
}
""", encoding='utf-8')
    (out / 'src/main/AndroidManifest.xml').write_text('''<manifest xmlns:android="http://schemas.android.com/apk/res/android">
<uses-permission android:name="android.permission.INTERNET"/>
<application android:label="Navi friend labels test" android:allowBackup="false" android:theme="@style/Theme.AppCompat.Light.NoActionBar">
<activity android:name="app.navi.mapprobe.FriendLabelsActivity" android:exported="true"/>
</application></manifest>''', encoding='utf-8')
    with (out / 'build.log').open('w', encoding='utf-8') as log:
        subprocess.run([args.gradle, '-p', str(out), 'assembleDebug', '--console=plain']
            + (['--offline'] if args.offline else []), stdout=log, stderr=subprocess.STDOUT, timeout=600, check=True)
    apk = out / 'build/outputs/apk/debug/NaviFriendLabelsProbe-debug.apk'
    subprocess.run(adb + ['install', '-r', str(apk)], timeout=120, check=True)
    subprocess.run(adb + ['shell', 'am', 'start', '-W', '-S', '-n', PACKAGE + '/.FriendLabelsActivity'], timeout=30, check=True)
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        pid = subprocess.run(adb + ['shell', 'pidof', PACKAGE], capture_output=True, text=True, timeout=10, check=True).stdout.strip()
        if not pid.isdecimal():
            raise RuntimeError('Test process missing or ambiguous')
        log = subprocess.run(adb + ['logcat', '-d', '--pid=' + pid, '-s', 'NaviFriendLabels:I', 'AndroidRuntime:E'],
                             capture_output=True, text=True, timeout=10, check=True).stdout
        (out / 'runtime.log').write_text(log, encoding='utf-8')
        if 'FAIL ' in log or 'FATAL EXCEPTION' in log:
            raise AssertionError(log)
        if log.count('PASS ') == 3:
            screenshot = subprocess.run(adb + ['exec-out', 'screencap', '-p'], capture_output=True, timeout=15, check=True)
            (out / 'cleared-peers.png').write_bytes(screenshot.stdout)
            (out / 'result.json').write_text(json.dumps({'passed': 3, 'glyph_sha256': GLYPH_SHA,
                'apk_sha256': hashlib.sha256(apk.read_bytes()).hexdigest(), 'avd': args.avd}, indent=2), encoding='utf-8')
            print('PASS 3 real GL friend-label checks; evidence:', out)
            return
        time.sleep(0.5)
    raise TimeoutError('Three rendered friend-label checks did not complete')


if __name__ == '__main__':
    main()
