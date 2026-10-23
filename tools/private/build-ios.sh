#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?Usage: build-ios.sh OUTPUT_DIRECTORY}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
if [[ -e "$OUT/Navi-Karte.ipa" ]]; then
  echo 'Refusing to reuse an existing IPA output path' >&2
  exit 1
fi
WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/navi-ios.XXXXXX")"
cd "$ROOT"
SOURCE_COMMIT="$(git rev-parse HEAD)"
./configure.sh
ruby tools/private/prepare-ios.rb
bash tools/private/test-ios.sh "$OUT" "$WORK/SimulatorDerivedData"
xcodebuild build \
  -workspace xcode/CoMaps.xcworkspace \
  -scheme CoMaps -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$WORK/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile \
  -xcconfig packaging/private/private-build.xcconfig \
  CODE_SIGN_ENTITLEMENTS="$ROOT/packaging/private/PrivateSideload.entitlements" \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM= \
  2>&1 | tee "$OUT/xcode-build.log"
APP_COUNT="$(find "$WORK/DerivedData/Build/Products/Release-iphoneos" -maxdepth 1 -name '*.app' | wc -l | tr -d ' ')"
[[ "$APP_COUNT" == 1 ]] || { echo 'Expected exactly one built device app' >&2; exit 1; }
APP="$(find "$WORK/DerivedData/Build/Products/Release-iphoneos" -maxdepth 1 -name '*.app' -print -quit)"
python3 - "$APP/Info.plist" "$SOURCE_COMMIT" <<'PY'
import plistlib,sys
from pathlib import Path
p=Path(sys.argv[1])
data=plistlib.loads(p.read_bytes())
data['NaviSourceCommit']=sys.argv[2]
data['CFBundleDisplayName']='Navi'
for key in ('NSUbiquitousContainers',):
    data.pop(key,None)
p.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_BINARY))
PY
mkdir "$WORK/Payload"
ditto "$APP" "$WORK/Payload/Navi.app"
(cd "$WORK" && /usr/bin/zip -qry -y "$OUT/Navi-Karte.ipa" Payload)
python3 tools/private/verify_artifacts.py --report "$OUT/ipa-report.json" ipa "$OUT/Navi-Karte.ipa" --require-maplibre
