# Screenshots

This directory is where F-Droid/Fastlane-style phone screenshots belong:

```
fastlane/metadata/android/en-US/images/phoneScreenshots/1.png
fastlane/metadata/android/en-US/images/phoneScreenshots/2.png
...
```

No screenshots are committed yet (no emulator/device was available to capture
them in the environment that generated this initial commit). To add them:

1. Install the debug build on a device or emulator.
2. Capture PNG screenshots of the main screen (idle state, a computed hash,
   and a MATCH/MISMATCH result are good candidates).
3. Save them here as `1.png`, `2.png`, `3.png`, etc. (order controls display
   order on F-Droid/store listings).
4. Optionally add a feature graphic at
   `fastlane/metadata/android/en-US/images/featureGraphic.png`.

An `icon.png` (512x512) can also be placed at
`fastlane/metadata/android/en-US/images/icon.png` for store listings that
want a raster icon in addition to the in-app adaptive icon.
