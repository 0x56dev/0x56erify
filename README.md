# 0x56erify

A minimal, offline checksum verification app for Android.

Pick a file with the system document picker, compute its SHA-256 or SHA-512
checksum, and compare it against an expected hash (for example, one
published next to a download) to get a clear **MATCH** / **MISMATCH**
result.

## Features

- Pick a file via Android's Storage Access Framework (system file picker)
- Compute SHA-256 or SHA-512
- Streamed hashing — large files are never loaded fully into memory
- Hashing runs off the UI thread and won't freeze the app
- Copy or share the computed hash
- Paste an expected hash; comparison is case-insensitive and whitespace-tolerant
- Clear error messages for cancelled pickers, unreadable files, and malformed
  expected hashes
- No accounts, no analytics, no ads, no tracking, no network access

## Privacy

0x56erify processes files locally on-device. It does not transmit files,
hashes, or usage data over the network.

The app requests no `INTERNET` permission and no broad storage permissions.
Files are only accessed through the system document picker, for the duration
of the hashing operation.

## Building

Requirements: JDK 17, Android SDK (platform 35, build-tools 35.0.0).

```bash
./gradlew assembleDebug   # build a debug APK
./gradlew testDebugUnitTest  # run unit tests
```

The debug APK is written to `app/build/outputs/apk/debug/`.

## Project structure

```
app/src/main/kotlin/dev/x56/verify/
  HashAlgorithm.kt     algorithm enum (SHA-256 / SHA-512)
  HashUtils.kt         pure hashing + comparison logic (unit-tested)
  VerifyViewModel.kt   UI state, SAF file access, background hashing
  MainActivity.kt      single-screen Jetpack Compose UI
app/src/test/kotlin/dev/x56/verify/
  HashUtilsTest.kt     unit tests for hashing and comparison logic
```

## F-Droid notes

This project is designed to be straightforward to submit to F-Droid:

- All dependencies are FOSS (AndroidX, Jetpack Compose, Kotlin coroutines —
  no Google Play Services, no Firebase, no proprietary SDKs or analytics).
- No network permissions or functionality of any kind.
- Complete source is committed; the build is a standard Gradle/AGP build
  with the Gradle wrapper included.
- License: Apache License 2.0 (see [`LICENSE`](LICENSE)).
- Fastlane-style metadata lives under
  `fastlane/metadata/android/en-US/` (`title.txt`, `short_description.txt`,
  `full_description.txt`, `changelogs/`). See
  `fastlane/metadata/android/en-US/images/phoneScreenshots/README.md` for
  screenshot instructions — none are committed yet.
- `versionName` starts at `0.1.0`, `versionCode` at `1`. Releases are tagged
  as `vX.Y.Z`.

Suggested F-Droid `Categories`: `Security`; `AntiFeatures`: none.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
