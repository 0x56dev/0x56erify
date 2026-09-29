# Release-tooling tests

Tests for `scripts/release/` only. The app's own unit tests are the Gradle
tests under `app/src/test/`.

```bash
scripts/release/tests/run.sh          # fast suite (~15 s): no network, no Gradle
scripts/release/tests/run.sh --full   # also a real Gradle-signed dry run of HEAD (a few minutes)
python3 scripts/release/tests/test_release_tool.py   # release_tool.py unit tests only
```

Requirements: `python3`, `jq`, `git`, `keytool`, `script` (util-linux),
`apksigcopier`, and an Android SDK with the build-tools version from
`release.conf` and at least one platform.

Everything runs in a temporary directory with a throwaway key; nothing
touches GitHub, this repository or the real release key.

| File | Purpose |
|---|---|
| `test_release_tool.py` | Unit tests with tiny synthetic ZIPs: exact signed/unsigned layout (padding rejected), signing-block inspection, strict manifest schema and tampering, release-notes rules, version parsing, JUnit summaries |
| `run.sh` | End-to-end fail-closed checks of `check-apk.sh`, `check-metadata.sh`/`release-preflight.sh` and `publish-release.sh` in a throwaway repository |
| `fixture/` | A minimal manifest and a stand-in `gradlew` that links a tiny APK with `aapt2` and signs it if `keystore.properties` exists (not a build system) |
| `mock/` | A stand-in for the few `gh`/`curl` calls the scripts make, with one failure switch per scenario |

What the suite is meant to protect: publishing refuses a wrong tag or commit,
a missing or ambiguous CI run, a wrong or expired artifact, a changed
manifest, the wrong certificate or signature schemes, unexpected
package/version/permissions, an existing release, and any local build that
isn't exactly the CI APK plus a signing block. There is no fallback signer,
the human-written notes are kept, a bad upload stays an unpublished draft, and
no temporary `keystore.properties` is left behind.

If you change a refusal message in the scripts, update the matching pattern
in `run.sh`.
