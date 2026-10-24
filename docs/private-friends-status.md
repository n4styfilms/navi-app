# Friends implementation status

The map/fuel Android package remains Karte05. The following source work is a foundation; neither packaged app yet offers a functioning friends list or account synchronization.

## Server access rules

`backend/firebase` has pinned local Auth/Realtime Database emulators and 18 passing multi-identity rule tests. Consent is bilateral; position, speed and trip access are distinct. Tests include an initial allowed live listener followed by permission cancellation after revoking friendship. Trip indexes and chunks expire after 30 days regardless of client cleanup. The rules have not been deployed to a real cloud project. See that directory's README for the supported bounded query and emulator cursor limitation.

## Presence quality and upload gate

Java and Swift domain modules copy samples from the existing location provider; they do not start a new GPS provider or connect to Firebase. Immutable samples retain accuracy and measurement time. Unknown/negative/nonfinite speed is omitted, not displayed as zero. Invalid coordinates or missing/nonfinite/negative accuracy cannot publish. Exactly 15 seconds is current; older or future measurements are not current. Bearings are normalized when finite.

At motion, reserve at most one upload every 5 seconds with the foreground map, or 15 seconds in the background. At rest, use 60 seconds. These are upload ceilings, not guarantees of background GPS delivery. Duplicate/reordered samples are rejected. Start/reconnect requires a newly measured sample. Pause, error, sign-out and account switch invalidate earlier generation tickets. A candidate must be rechecked immediately before sending; a newer candidate supersedes older queued candidates, and stale candidates expire.

The repository still must persist/bootstrap monotonically increasing sequence values, use the one existing location stream, adjust for server time, discard Firebase-pending writes on pause/sign-out, remove old listeners/markers, and complete server-side revocation. A local generation guard alone cannot revoke an already in-flight network operation. Swift policy is isolated to the main actor; Android methods synchronize policy state, while the sending repository must serialize the final recheck/write operation.

27 shared literal traces cover freshness, quality, cadence, pause, stale queued work, reconnect and account changes. Actual Java and Apple Swift runs pass, including the blank-owner regression caught and fixed on Apple. [Host run 40051962422](https://github.com/n4styfilms/navi-app/actions/runs/40051962422), source `6551cdddf0cbb52c5235449237ba7021ff8d8a1d`, passed 45 executed tests with two explicit skips out of 47 discovered tests. This includes the real C++/JNI/JVM snapshot mapper after checking out its pinned UTF-8 header dependency.

The Swift files still require target integration with the account repository. No fresh APK/IPA is claimed for these source modules. There is no configured real cloud service or two-device background test yet.
