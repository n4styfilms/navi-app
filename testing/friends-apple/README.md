# Apple native friends session fixture

The `Native Apple friends sessions` workflow runs real Firebase Core/Auth/Database 13.1.1 in an iPhone Simulator app on a standard macOS runner against local Auth and Realtime Database emulators. No real Firebase project, Apple developer membership or signing credentials are used. The executable uses three synthetic identities and the shipping locked database rules.

`tools/private/prepare-friends-apple.py NEW_DIRECTORY` copies the production Swift domain sources and fixture app into an isolated directory and records their checksums. `python3 tools/private/build-friends-apple.py NEW_DIRECTORY` generates an Xcode app project and compiles the actual SDK and domain code for Simulator. Normal ad-hoc Simulator signing uses no developer certificate or paid account. Inside `backend/firebase`, after `npm ci`, run:

```sh
npx firebase emulators:exec --project demo-navi-friends --only auth,database "node tests/native-apple.mjs '/absolute/NEW_DIRECTORY/.build/debug/FriendsNativeProbe' '/absolute/report.json'"
```

The harness requires a demo project, applies the shipping rules to the local emulator and requires a successful native process plus all three named proof flags. It records the actual transcript before asserting. Auth credentials and coordinates are synthetic, and peer data is memory-only. It tests copied native identity with forced token refresh, server cancellation after global pause, synchronous local cleanup preserving the primary identity, and a new unauthorized account receiving zero old peer values.

The first actual run 40195746044 proved the missing production session type by failing compilation. Run 40196054447 compiled the implementation but exposed a test-host problem: a bare Mac executable cannot use the normal app Keychain without its app entitlement context (SecItemAdd -34018). The fixture now uses a real Simulator app and the normal Auth SDK; no substitute password storage or Keychain bypass is used. The new candidate is under test; no successful runtime result is claimed here yet. Foreground/background location, map binding, account UI, a device install and friends support in the delivered IPA remain unproven.

SDK prerequisites and public API references: [Apple setup](https://firebase.google.com/docs/ios/setup), [13.1.1 release notes](https://firebase.google.com/support/release-notes/ios), [Auth](https://firebase.google.com/docs/reference/swift/firebaseauth/api/reference/Classes/Auth), [Database](https://firebase.google.com/docs/reference/swift/firebasedatabase/api/reference/Classes/Database).
