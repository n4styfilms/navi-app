#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?Usage: test-ios.sh OUTPUT_DIRECTORY DERIVED_DATA}"
DERIVED="${2:?Usage: test-ios.sh OUTPUT_DIRECTORY DERIVED_DATA}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cd "$ROOT"
# configure.sh and prepare-ios.rb must already have run in the disposable checkout.
xcrun simctl list devices available --json > "$OUT/simulator-inventory.json"
python3 tools/private/select_ios_simulator.py "$OUT/simulator-inventory.json" > "$OUT/simulator-destination.json"
UDID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["udid"])' "$OUT/simulator-destination.json")"
set +e
xcodebuild test \
  -workspace xcode/CoMaps.xcworkspace -scheme CoMaps -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" -resultBundlePath "$OUT/ios-tests.xcresult" \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGN_ENTITLEMENTS="$ROOT/packaging/private/PrivateSideload.entitlements" \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM= \
  2>&1 | tee "$OUT/xcode-tests.log"
TEST_PIPE_STATUS=("${PIPESTATUS[@]}")
set -e
if [[ "${TEST_PIPE_STATUS[0]}" != 0 ]]; then
  python3 tools/private/collect_ios_failure.py --out "$OUT" --derived "$DERIVED" --udid "$UDID" \
    || echo 'Additional simulator failure collection was incomplete; original test failure is preserved' >&2
  exit "${TEST_PIPE_STATUS[0]}"
fi
if [[ "${TEST_PIPE_STATUS[1]}" != 0 ]]; then
  exit "${TEST_PIPE_STATUS[1]}"
fi
xcrun xcresulttool get test-results summary --path "$OUT/ios-tests.xcresult" > "$OUT/ios-test-summary.json"
# Keep actual main-map / Friends screenshots produced by the hosted UIKit test.
# The xcresult remains authoritative even if attachment export itself is unavailable.
xcrun xcresulttool export attachments --path "$OUT/ios-tests.xcresult" --output-path "$OUT/ui-attachments" \
  > "$OUT/ui-attachment-export.log" 2>&1 || echo 'UI attachments remain in the original xcresult bundle' >&2
python3 - "$OUT/ios-test-summary.json" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1]))
if not isinstance(summary.get('passedTests'), int) or summary['passedTests'] < 1 or summary.get('failedTests') != 0:
    raise SystemExit('iOS test result does not establish executed passing tests; inspect actual xcresult summary')
print('Verified executed iOS tests:', summary['passedTests'])
PY
