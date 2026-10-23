#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?Usage: build-android.sh OUTPUT_DIRECTORY}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
[[ ! -e "$OUT/Navi-Karte-unsigned.apk" ]] || { echo 'Refusing to reuse existing APK' >&2; exit 1; }
cd "$ROOT"
SOURCE_COMMIT="$(git rev-parse HEAD)"
./configure.sh
python3 - "$SOURCE_COMMIT" <<'PY'
import json,sys
from pathlib import Path
Path('android/sdk/src/main/assets/private-build.json').write_text(json.dumps({'source_commit':sys.argv[1]}),encoding='utf-8')
PY
cd android
collect_unit_reports() {
  if [[ -d "$ROOT/android/app/build/test-results/testWebBetaUnitTest" ]]; then
    cp -R "$ROOT/android/app/build/test-results/testWebBetaUnitTest" "$OUT/android-unit-tests"
  fi
}
trap collect_unit_reports EXIT
# Catch Java/resource integration failures before spending runner time compiling the C++ core.
./gradlew --no-daemon -Parm64 -PnaviPrivate -Pnjobs=2 :app:compileWebBetaJavaWithJavac 2>&1 | tee "$OUT/android-build.log"
./gradlew --no-daemon -Parm64 -PnaviPrivate -Pnjobs=2 testWebBetaUnitTest assembleWebBeta 2>&1 | tee -a "$OUT/android-build.log"
mapfile -t APKS < <(find app/build/outputs/apk/web/beta -name '*.apk')
[[ "${#APKS[@]}" == 1 ]] || { echo 'Expected exactly one built APK' >&2; exit 1; }
cp "${APKS[0]}" "$OUT/Navi-Karte-unsigned.apk"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:?Android SDK path missing}}"
TOOLS="$SDK/build-tools/36.0.0"
cd "$ROOT"
"$TOOLS/aapt2" dump badging "$OUT/Navi-Karte-unsigned.apk" > "$OUT/apk-badging.txt"
# This is an intermediate unsigned build. Local signing and the normal strict
# package verifier are mandatory before it becomes an installable deliverable.
python3 - "$OUT" "$SOURCE_COMMIT" <<'PY'
import hashlib, json, sys, zipfile
from pathlib import Path
out = Path(sys.argv[1]); apk = out/'Navi-Karte-unsigned.apk'
with zipfile.ZipFile(apk) as archive:
    libraries = [name for name in archive.namelist() if name.endswith('.so')]
    assert 'lib/arm64-v8a/liborganicmaps.so' in libraries
    assert 'lib/arm64-v8a/libmaplibre.so' in libraries
    assert {name.split('/')[1] for name in libraries} == {'arm64-v8a'}, 'Unexpected ABI without matching core'
report = {'source_commit':sys.argv[2], 'file':apk.name,
          'sha256':hashlib.sha256(apk.read_bytes()).hexdigest(),
          'native_libraries':libraries, 'signing_pending':True,
          'installable_deliverable':False, 'navigation_tested':False}
(out/'unsigned-build.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
PY
