# Native friend-label regression

`../run-friend-labels-android.py` builds the shipping `NaviMapController`, map domain classes and route snapshot against MapLibre Android 13.7.1. It runs `FriendLabelsActivity` in the separate `app.navi.mapprobe` package on an explicitly named disposable x86_64 AVD (tested API 36). It does not install, clear or change the main Navi app.

Download the public test glyph with normal certificate validation:

```sh
curl --fail --output noto-0-255.pbf 'https://tiles.openfreemap.org/fonts/Noto%20Sans%20Regular/0-255.pbf'
```

The runner checks SHA256 `ef1f38a3f1978591e846e9eaddf8a54f7047f546fc6aaed7872cc53151a5de78` before using it. The binary is not committed. If the upstream font changes, inspect the new public data before updating the pin.

With JDK and Android SDK configured:

```sh
python tools/private/run-friend-labels-android.py --out /absolute/new/evidence-directory --gradle /path/to/gradle --adb /path/to/adb --serial emulator-5554 --avd YOUR_DISPOSABLE_AVD --glyph /path/to/noto-0-255.pbf
```

The output directory must not already exist. `--offline` uses installed Gradle dependencies; optional repeated `--maven-directory` adds predownloaded local Maven repositories. Neither option relaxes certificate validation. Use the existing verified Gradle executable if the wrapper distribution is not already installed.

The test intercepts all map requests with a minimal style and the pinned public glyph. Unknown fonts return 404, matching the default font-stack failure observed on OpenFreeMap. No live map request, user location, Firebase account or certificate override is used. It requires all three actual GL checks: friend dot/name/speed rendered without a route, retained after style reload with unchanged camera, and absent after clearing peers. Source checksums, build/runtime logs, APK checksum and the cleared-state screenshot are retained.

This is a renderer regression, not evidence of live satellite glyphs, authenticated friends on the main map, or whole-app background sharing. The originally delivered Freunde-01 APK predates the font correction.
