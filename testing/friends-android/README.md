# Native friends integration fixture

This isolated Android application compiles the real production friends sources against Firebase Auth/Database, pinned by BoM 34.19.0 (Auth 24.2.0, Database 22.0.1). BoM 35's Auth 25 requires API 24, so this compatible stable line preserves the main app's API 23 minimum. The manifest merger caught this before any library override or minimum-version change. It is a test harness, not the Navi package for users. Its application ID is `app.navi.friendstest`; it never reads the `app.navi.private` sandbox or changes that app's signing key/data.

Build with the existing wrapper: `android/gradlew -p testing/friends-android assembleDebug` from the repository root. The small fixture uses cached-compatible AGP 8.11.1 independently of the main application's AGP. Its debug signature uses the existing public CoMaps development key so fixture updates do not require deleting installed test data. No private Navi key is uploaded or used here.

Install the resulting debug APK into the owned test emulator. Start the local `demo-navi-friends` Auth and Realtime Database emulators and load the checked-in rules for that namespace, then run `adb -s emulator-5554 shell am instrument -w app.navi.friendstest/app.organicmaps.navi.friends.FriendsSessionInstrument`. Require `INSTRUMENTATION_CODE: -1` and all four native proof flags. A process exit code alone is insufficient because Android's instrumentation shell can return zero even when a test reports failure.

All identities, passwords, coordinates and accounts are synthetic and local. No Cloud project or real credential is used. Only this test APK permits cleartext traffic to `10.0.2.2`, the Android emulator alias for the host's loopback services. The shipping app's TLS/certificate/network settings are untouched. The fixture does not start GPS or claim a physical drive/background test.

Tests cover copying real authenticated users into independent named data FirebaseApps, actual server cancellation of a permitted native listener, no cached peer values delivered after a switch to an unauthorized account, and cleanup of a delayed session-open result after sign-out. The delayed completion seam still opens a real native SDK session; it controls delivery timing rather than mocking authentication or database permissions.

Until the production session classes exist and actual instrumentation passes, this fixture is an executable failing specification, not completed integration evidence.
