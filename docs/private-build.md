# Private Navi basis

Upstream: CoMaps, pinned at 0446bbe9d519f3024486086a038bcea9c9d7f8fd. Apache-2.0; preserve LICENSE, NOTICE and OSM attribution. This is the existing navigation baseline, not yet the approved custom UI, fuel calculator or friend tracking.

Both workflows are manual only. Use standard GitHub-hosted runners inside the free allowance, with paid overage blocked at $0. Retention is one day; download the artifacts promptly. No Apple signing account, secret or provisioning service is used.

## Android

The manual `Private Android APK` workflow prepares upstream resources and builds ARM64 `WebBeta` on Ubuntu 24.04. The supplied Windows script can build once those resources have been prepared in a complete host environment; Android SDK alone does not provide Qt, the host C++ compiler or image tools. For this machine the free Linux runner avoids installing a large host toolchain.

This initial beta APK uses the public upstream DEVELOPMENT key. It is for baseline testing, not trusted production distribution. Before any friend accounts or private location history are added, create a dedicated private release key and retain it for all subsequent updates. The verifier invokes both aapt2 and apksigner; a renamed ZIP is not accepted.

## iOS

The manual `Private iOS IPA` workflow uses Xcode 26.6 on standard macOS 26. It builds ARM64 for physical iOS devices with signing disabled. A build-only Ruby transformation removes the optional widget extension dependency and uses an empty private entitlement set. Push, CarPlay, iCloud, associated domains and app groups are not required.

Open the downloaded IPA with your free sideloader. The sideloader signs and installs it; its refresh requirements still apply. The unsigned IPA is not directly installable by tapping it. Main navigation and background location still require physical-device testing. CoMaps iCloud options are not functional in this private variant.

## Evidence

`apk-report.json` / `ipa-report.json` contain the package hash and source commit embedded at build time. The IPA verifier reads the Mach-O platform, including embedded frameworks, rather than assuming that ARM64 means a physical iPhone. Simulator and macOS binaries are rejected.

Run: `python -m unittest discover -s tools/private/tests -v`.

On a host with the pinned Android SDK/NDK, the suite also links real ARM64 C and C++ shared libraries with IPO. This caught CMake 3.22.1 selecting the unavailable gold linker with the NDK r28 legacy toolchain. The Android-only compatibility module explicitly selects the NDK's LLD while retaining IPO.

The delivery manifest defaults to requiring both packages from `--commit`. If a platform-only fix leaves a previously successful package unchanged, `--apk-commit` / `--ipa-commit` may explicitly identify separate sources. Each report must still match its declared platform commit and actual package hash. In that case the common `source_commit` is null and `source_commits` plus each artifact record retain the real separate commits. The run ID identifies both build runs; the delivery report links each run. An older package is never relabeled as the newer source. This avoids consuming macOS minutes to rebuild an unchanged iOS package after an Android-only correction.

The build scripts refuse to reuse an existing output package path. Generated source assets and private package metadata are excluded from Git. A successful build and a successful package check do not mean that a phone was used to test it.
