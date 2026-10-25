"""Generate an isolated real Apple Firebase SDK fixture from shipping Swift sources."""
import hashlib
import json
from pathlib import Path
import shutil
import sys

root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=False)
sources = out / 'Sources/FriendsNativeProbe'
sources.mkdir(parents=True)
files = list((root / 'iphone/Maps/UI/NaviFriends').glob('*.swift'))
files.append(root / 'testing/friends-apple/FriendsNativeProbe.swift')
for source in files:
    shutil.copyfile(source, sources / source.name)
(out / 'source-copies.json').write_text(json.dumps([
    {'source': p.relative_to(root).as_posix(), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
    for p in files], indent=2), encoding='utf-8')
(out / 'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "FriendsNativeProbe", platforms: [.macOS(.v12), .iOS(.v15)],
  dependencies: [.package(url: "https://github.com/firebase/firebase-ios-sdk.git", exact: "13.1.1")],
  targets: [.executableTarget(name: "FriendsNativeProbe", dependencies: [
    .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
    .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
    .product(name: "FirebaseDatabase", package: "firebase-ios-sdk")])],
  swiftLanguageModes: [.v5])
''', encoding='utf-8')
print(out)
