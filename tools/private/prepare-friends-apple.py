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
domain = root / 'iphone/Maps/UI/NaviFriends'
files = [domain / name for name in ('PresenceSample.swift', 'PresencePolicy.swift', 'FriendsDataSession.swift',
    'FriendsGroupConfiguration.swift', 'FriendsAccountController.swift', 'FriendsRepository.swift', 'FriendsObservation.swift', 'FriendsSharingController.swift', 'FriendsSignOutCoordinator.swift', 'FriendsRuntime.swift', 'FriendsSheetController.swift') if (domain / name).exists()]
palette = root / 'iphone/Maps/UI/Vehicle/NaviPalette.swift'
if palette.exists():
    files.append(palette)
files.extend([root / 'testing/friends-apple/FriendsNativeProbe.swift', root / 'testing/friends-apple/FriendsProbeApp.swift',
    root / 'testing/friends-apple/FriendsSnapshotScenario.swift', root / 'testing/friends-apple/FriendsSharingScenario.swift', root / 'testing/friends-apple/FriendsSignOutScenario.swift', root / 'testing/friends-apple/FriendsRuntimeScenario.swift', root / 'testing/friends-apple/FriendsSheetScenario.swift'])
for source in files:
    shutil.copyfile(source, sources / source.name)
(out / 'source-copies.json').write_text(json.dumps([
    {'source': p.relative_to(root).as_posix(), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
    for p in files], indent=2), encoding='utf-8')
print(out)
