"""Build/run the actual Framework navigation scenario on a selected Android device.

Requires the configured Android CMake build. Does not install an APK or test map UI.
"""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("sdk", "build", "data", "resource-apk", "out"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--serial", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    sdk, build, data = args.sdk.resolve(), args.build.resolve(), args.data.resolve()
    suffix = ".exe" if (sdk / "platform-tools/adb.exe").exists() else ""
    cmake = sdk / ("cmake/3.22.1/bin/cmake" + suffix)
    adb = sdk / ("platform-tools/adb" + suffix)
    cache = (build / "CMakeCache.txt").read_text(encoding="utf-8")
    if "NAVI_HEADLESS_TEST:BOOL=ON" not in cache or "28.2.13676358" not in cache:
        raise RuntimeError("Configure this tree with NAVI_HEADLESS_TEST=ON and pinned NDK 28.2.13676358 first")
    countries = json.loads((root / "data/countries.txt").read_text(encoding="utf-8"))
    records = {}
    stack = list(countries["g"])
    while stack:
        entry = stack.pop()
        records[entry["id"]] = entry
        stack.extend(entry.get("g", []))
    maps = {}
    for name in ("World", "Monaco", "France_Provence-Alpes-Cote dAzur_Maritime Alps"):
        path = data / (name + ".mwm")
        expected = records[name]
        if path.stat().st_size != expected["s"] or base64.b64encode(hashlib.sha1(path.read_bytes()).digest()).decode() != expected["sha1_base64"]:
            raise RuntimeError("Map size/checksum mismatch: " + name)
        maps[path.name] = {"bytes": path.stat().st_size, "sha256": digest(path)}
    with zipfile.ZipFile(args.resource_apk) as apk:
        resource_countries = json.loads(apk.read("assets/countries.txt"))
        if resource_countries["v"] != countries["v"]:
            raise RuntimeError("Resource APK and test maps use different versions")
        apk.getinfo("assets/classificator.txt")
    log = out / "headless.log"
    log.write_text("", encoding="utf-8")

    def run(command, timeout=60):
        result = subprocess.run([str(arg) for arg in command], cwd=root, capture_output=True,
                                text=True, encoding="utf-8", errors="replace", timeout=timeout)
        with log.open("a", encoding="utf-8") as stream:
            stream.write(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError((result.stdout + result.stderr)[-6000:])
        return result.stdout.strip()

    if run([adb, "-s", args.serial, "get-state"], 15) != "device":
        raise RuntimeError("Selected Android device is unavailable")
    run([cmake, "--build", build, "--target", "navi_headless_tests", "--parallel", "2"], 1200)
    executable = build / "navi_headless_tests"
    remote = "/data/local/tmp/navi-headless"
    run([adb, "-s", args.serial, "shell", "mkdir", "-p", remote])
    run([adb, "-s", args.serial, "push", args.resource_apk, remote + "/resources.apk"])
    for name in maps:
        run([adb, "-s", args.serial, "push", data / name, remote + "/" + name])
    run([adb, "-s", args.serial, "push", executable, remote + "/test"])
    run([adb, "-s", args.serial, "shell", "chmod", "700", remote + "/test"])
    result = run([adb, "-s", args.serial, "shell", remote + "/test", remote + "/resources.apk", remote], 180)
    success = "PASS real-map headless navigation, GPS, TTS, reroute, cancellation and failure"
    replay = re.search(r"Replay: GPS=(\d+) TTS=(\d+)", result)
    if (success not in result or "PASS failed reroute keeps old navigation" not in result or
            not replay or int(replay[1]) < 4 or int(replay[2]) < 1):
        raise RuntimeError("Headless scenario did not complete all assertions")
    points = [[float(lat), float(lon)] for lat, lon in re.findall(r"Replay point: ([\d.-]+) ([\d.-]+)", result)]
    if len(points) != int(replay[1]):
        raise RuntimeError("Synthetic mobile replay fixture is incomplete")
    (out / "synthetic-gps.json").write_text(json.dumps({
        "source": "public Monaco route from native test, not personal location history",
        "start": [43.7295, 7.4208], "destination": [43.745, 7.427],
        "points_lat_lon": points, "speed_mps": 8, "interval_seconds": 12}, indent=2) + "\n", encoding="utf-8")
    source_names = ["libs/map/framework.cpp", "libs/map/routing_manager.cpp", "libs/map/routing_manager.hpp",
                    "libs/map/navi_route_capture.cpp", "libs/map/navi_route_snapshot.cpp",
                    "libs/routing/routing_session.cpp", "libs/routing/road_warnings.cpp",
                    "libs/map/map_tests/navi_headless_routing_scenario.cpp",
                    "tools/private/tests/navi_test_platform.cpp", "tools/private/tests/navi_headless_test.cpp"]
    report = {
        "tested_at_utc": datetime.now(timezone.utc).isoformat(), "result": success,
        "binary_sha256": digest(executable), "resource_apk_sha256": digest(args.resource_apk),
        "resource_apk_usage": "unchanged baseline assets only; APK not installed",
        "source_sha256": {name: digest(root / name) for name in source_names},
        "map_version": countries["v"], "maps": maps,
        "device_api": run([adb, "-s", args.serial, "shell", "getprop", "ro.build.version.sdk"]),
        "device_abi": run([adb, "-s", args.serial, "shell", "getprop", "ro.product.cpu.abi"]),
        "gps_replay_events": int(replay[1]), "core_tts_events": int(replay[2]),
        "real_map_core_navigation_tested": True, "core_traffic_lights_tested": True,
        "failed_reroute_retains_navigation_tested": True,
        "app_installed": False, "visible_map_tested": False, "physical_drive_tested": False,
        "satellite_tested": False, "ios_tested": False,
    }
    (out / "headless-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(success)
    print(f"GPS: {replay[1]}; core TTS: {replay[2]}")
    print("Report:", out / "headless-report.json")


if __name__ == "__main__":
    main()
