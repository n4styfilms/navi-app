"""Fetch and verify the exact upstream maps needed by the headless Monaco case."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import urllib.parse
import urllib.request

MAPS = ("World", "WorldCoasts", "Monaco", "France_Provence-Alpes-Cote dAzur_Maritime Alps")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("out", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    countries = json.loads((root / "data/countries.txt").read_text(encoding="utf-8"))
    records = {}
    stack = list(countries["g"])
    while stack:
        record = stack.pop()
        records[record["id"]] = record
        stack.extend(record.get("g", []))
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    report = {"map_version": countries["v"], "map_series": countries["map_series"], "files": {}}
    base = f'https://mapgen-fi-1.comaps.app/maps/{countries["map_series"]}/{countries["v"]}/'
    for name in MAPS:
        expected = records[name]
        target = out / (name + ".mwm")

        def verified(path):
            if not path.is_file() or path.stat().st_size != expected["s"]:
                return False
            return base64.b64encode(hashlib.sha1(path.read_bytes()).digest()).decode() == expected["sha1_base64"]

        url = base + urllib.parse.quote(target.name)
        if not verified(target):
            temporary = target.with_suffix(".mwm.part")
            with urllib.request.urlopen(url, timeout=60) as response, temporary.open("wb") as stream:
                while block := response.read(1024 * 1024):
                    stream.write(block)
            if not verified(temporary):
                raise RuntimeError(f"Upstream size/SHA-1 mismatch: {name}")
            temporary.replace(target)
        report["files"][target.name] = {
            "url": url, "bytes": target.stat().st_size,
            "sha1_base64": expected["sha1_base64"],
            "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
        }
        print("Verified", target.name, flush=True)
    (out / "route-data-manifest.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
