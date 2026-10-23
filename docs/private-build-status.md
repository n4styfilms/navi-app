# Baseline package evidence

Status on 2026-10-18: actual Android APK and unsigned physical-device iOS IPA built, downloaded and independently reverified locally. No physical phone installation or navigation test has been performed. This is the CoMaps navigation baseline; custom UI, fuel estimation and friend sharing are future work.

| Platform | Successful run | Embedded source | SHA-256 |
|---|---|---|---|
| Android ARM64 | [39071512302](https://github.com/n4styfilms/navi-private/actions/runs/39071512302) | `e82fc44153f490b401365268cee6c725b21a2747` | `9cd1a7fcf3493ecbd382e989febbee6b5302a75d4b5c23ab77f5cab33fdfb1cc` |
| iOS ARM64 device | [39069798795](https://github.com/n4styfilms/navi-private/actions/runs/39069798795) | `2226e40f5a0033852830998c12b985036c22a0f0` | `b1da0dd6714849fa3b23b04cbc636c20fda9f49b23a949d8f3fa2f05107cccc9` |

Android package ID: `app.comaps.test`, development signing key; signature verified by apksigner. iOS bundle ID: `app.navi.private`, unsigned, MinimumOSVersion 15.6, no restricted entitlements detected. Personal sideload signing remains untested on an iPhone.

The first Android job failed at its final IPO link because CMake 3.22.1 selected gold under the NDK r28 legacy toolchain. The Android-only LLD fix was reproduced and validated using actual C and C++ ARM64 shared-library builds. The corrected complete Android job then succeeded. All 22 final tool tests passed and the private changes received a final read-only review with no substantiated findings.

The successful original iOS artifact is retained without relabeling. The Android fix does not change iphone, xcode, libs or third-party sources. The paired delivery manifest records the explicit separate platform commits and both run IDs; its common source_commit is null. Actual artifact hashes must still match each platform report.

Delivered binaries, JSON reports, SHA256SUMS and the German installation/report files are saved in the user's local `outputs/builds/Basis-01` delivery folder, outside this Git checkout. They are not committed to Git. GitHub artifacts have one-day retention; local delivered files do not depend on that retention.
