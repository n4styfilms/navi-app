# Friends database rules

This directory contains the local, server-enforced consent and data-access foundation. It is not a configured cloud service or a completed friends UI. No cloud project, deployment, billing account or personal credentials are included.

Use Node 24+, Java 21+ on `PATH`, then `npm ci` and `npm test`. The pinned CLI starts Auth and Realtime Database emulators only on loopback, with the `demo-navi-friends` project. Tests use three synthetic authenticated identities plus an anonymous client. Test setup uses the emulator's administrator fixture API; all assertions use normal client permissions.

Both users must approve friendship. Position, speed and trips have separate grants. Speed additionally requires position permission and the same position sequence. Grants alone never upload a location. Root data catalogs are unreadable. The listener test requires an initial allowed position before revoking consent and observing permission cancellation.

Only the owner writes a location, profile or trip. Current position updates require an increasing positive integer sequence and `receivedAtMs` set with the Firebase server timestamp transform. Optional speed is omitted when unknown. Profiles contain only a display name. Requests contain only a server timestamp; account addresses and passwords belong in Firebase Auth, never these nodes.

Trip index and chunk reads enforce the same 30-day retention, even before cleanup. Create the index before uploading chunks. A chunk has at most 100 point keys (`0`–`99`); a trip has at most 1000 chunk keys (`0`–`999`). Every point's measurement time must be inside the recorded trip. Deletion of the index makes remaining chunks unreadable. Cleanup, pause-generation handling and device synchronization still need implementation.

Trip-list consumers must query `tripIndex/{owner}` using `orderByChild('endedAtMs')` and a numeric `startAt` inside the permitted interval. Use server-adjusted time and a small positive safety margin: `serverNowMs - 30 * 86400000 + 60000.5`. This omits the oldest minute at the cutoff and avoids permission failures from small clock skew. Each individual index/chunk remains independently protected by its end time.

The fractional millisecond is intentional: pinned Database Emulator 4.11.2 rejects numeric comparisons on integral query cursors, even `query.startAt > 0` with `startAt(1)`, while accepting `startAt(1.5)`. Isolated tests verified equal client/server clocks, passing identity and ordering checks, and the failure for both `get` and live listeners. Neither deployed rules nor emulator binaries were weakened or patched. The query tests use fractional cursors for BOTH the denied old bound and allowed recent bound, so a blanket numeric denial cannot produce a false pass. Real cloud/native-SDK integration remains unverified.

References: [query-based rules](https://firebase.google.com/docs/database/security/rules-conditions), [emulator test API](https://firebase.google.com/docs/reference/emulator-suite/rules-unit-testing/rules-unit-testing), [CLI release notes](https://firebase.google.com/support/release-notes/cli). Versions and behavior checked 23 October 2026.
