#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="${1:?Usage: test-native.sh BUILD_DIRECTORY DATA_DIRECTORY}"
DATA="${2:?Usage: test-native.sh BUILD_DIRECTORY DATA_DIRECTORY}"
mkdir -p "$BUILD" "$DATA"
BUILD="$(cd "$BUILD" && pwd)"
DATA="$(cd "$DATA" && pwd)"
cd "$ROOT"
# Generate upstream resources, Boost headers and repo-local protobuf environment.
./configure.sh
source tools/unix/activate_venv.sh
python3 tools/private/fetch-route-test-data.py "$DATA"
# Keep tests' mutable settings/writable maps outside the source resource directory.
cp data/minsk-pass.mwm "$DATA/minsk-pass.mwm"
cmake -S . -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release -DSKIP_QT_GUI=ON \
  -DSKIP_TESTS=OFF -DSKIP_TOOLS=ON -DUSE_PCH=OFF -DNJOBS=2 \
  -DPython3_EXECUTABLE="$(command -v python3)" 2>&1 | tee "$BUILD/configure.log"
cmake --build "$BUILD" --target map_tests routing_tests --parallel 2 2>&1 | tee "$BUILD/build.log"
export QT_QPA_PLATFORM=offscreen
(cd tools/python/test_server && python3 start_server.py)
trap '(cd "$ROOT/tools/python/test_server" && python3 stop_server.py) || true' EXIT
python3 - <<'PY'
import socket, time
deadline = time.monotonic() + 20
while True:
    try:
        with socket.create_connection(('127.0.0.1', 34568), timeout=1):
            break
    except OSError:
        if time.monotonic() >= deadline:
            raise RuntimeError('Upstream local test server did not start')
        time.sleep(0.1)
PY
python3 tools/private/run-native-suites.py "$BUILD" "$DATA" "$ROOT/data"
