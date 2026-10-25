# Apple native friends session fixture

The `Native Apple friends sessions` workflow runs real Firebase Core/Auth/Database 13.1.1 on a standard macOS runner against local Auth and Realtime Database emulators. No real Firebase project, Apple developer membership or signing credentials are used. The executable uses three synthetic identities and the shipping locked database rules.

`tools/private/prepare-friends-apple.py NEW_DIRECTORY` copies the production Swift domain sources into an isolated Swift package and records their checksums. `swift build --package-path NEW_DIRECTORY` compiles the actual SDK and domain code. Inside `backend/firebase`, after `npm ci`, run:

```sh
npx firebase emulators:exec --project demo-navi-friends --only auth,database "node tests/native-apple.mjs '/absolute/NEW_DIRECTORY/.build/debug/FriendsNativeProbe' '/absolute/report.json'"
```

The harness requires a demo project, applies the shipping rules to the local emulator and requires a successful native process plus all three named proof flags. It records the actual transcript before asserting. Auth credentials and coordinates are synthetic, and peer data is memory-only. It tests copied native identity with forced token refresh, server cancellation after global pause, synchronous local cleanup preserving the primary identity, and a new unauthorized account receiving zero old peer values.

The first actual run 40195746044 proved the missing production session type by failing compilation. The implementation candidate is under test; no successful runtime result is claimed here yet. This fixture runs Apple SDKs on macOS. It does not prove iOS Simulator UI, foreground/background location, map binding, a device install or friends support in the delivered IPA. Those integration steps remain required.

SDK prerequisites and public API references: [Apple setup](https://firebase.google.com/docs/ios/setup), [13.1.1 release notes](https://firebase.google.com/support/release-notes/ios), [Auth](https://firebase.google.com/docs/reference/swift/firebaseauth/api/reference/Classes/Auth), [Database](https://firebase.google.com/docs/reference/swift/firebasedatabase/api/reference/Classes/Database).
