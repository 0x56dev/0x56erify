# Releasing 0x56erify

GitHub releases are built twice, by CI and on your machine, and must match
exactly before the locally signed APK is published:

```
 local preflight ──> push to main ──> "Release preflight" workflow (manual, no tag yet)
                                              │ passes: reports the exact commit
                                              v
                      git tag -a vX.Y.Z <commit> && git push origin vX.Y.Z
                                              │
                                              v
                      "Release" workflow (tag push): same checks + tag checks,
                      builds the UNSIGNED APK, uploads it with release-manifest.json
                                              │
                                              v
         scripts/release/publish-release.sh vX.Y.Z  (your machine, your key)
         verifies tag + run + artifact + manifest; rebuilds the tagged commit
         with Gradle, signed by AGP as for v0.1.0-v0.1.3; requires it to equal
         the CI APK plus a signing block; verifies; publishes
```

- **The signing key never leaves your machine.** CI has no secrets, can't sign
  and has read-only repository access. It never creates, moves or deletes
  tags, and never creates releases.
- **Same signing path as every earlier release.** The published APK is signed
  by the Android Gradle Plugin during a normal local `assembleRelease`, using
  your existing `keystore.properties`. There is no other signing method and no
  fallback: if the local build doesn't match CI's, nothing is published.
- **Tags are immutable.** Once `vX.Y.Z` is pushed it's never moved or reused.
  Every check that can run before tagging does, so a typo doesn't burn a
  version number.
- **Release notes are human-written** (`.github/release-notes/vX.Y.Z.md`) and
  published as written, plus a generated `## This build` section. See
  [`.github/release-notes/README.md`](../.github/release-notes/README.md).

## F-Droid depends on the GitHub release

F-Droid's metadata for `dev.x56.verify` uses **reproducible builds with our
signature**:

```yaml
Binaries: https://github.com/0x56dev/0x56erify/releases/download/v%v/0x56erify-%v.apk
AllowedAPKSigningKeys: 0e454cec0c016fb821b817ebcc2aa48ddf7c0efe1f468d905b140400b3a26c3d
UpdateCheckMode: Tags
UpdateCheckData: app/build.gradle.kts|versionCode\s*=\s*(\d+)|...|versionName\s*=\s*"([^"]+)"
```

F-Droid builds each new `v*` tag itself and downloads our APK from the
`Binaries` URL. It publishes our signed APK only if its certificate is the one
above and F-Droid's unsigned build matches it byte for byte, apart from the
signature. So:

- the asset name `0x56erify-<version>.apk` and the tag format `v<version>`
  must never change;
- the signing certificate must never change (`SIGNING_CERT_SHA256` in
  [`scripts/release/release.conf`](../scripts/release/release.conf));
- `versionCode`/`versionName` must each appear exactly once in
  `app/build.gradle.kts` (F-Droid's regexes take the first match);
- **publish promptly after tagging.** F-Droid's bot picks up new tags, and if
  the APK isn't at the `Binaries` URL when F-Droid builds, that version's build
  fails.

`publish-release.sh` already performs the same comparison F-Droid will. The
locally signed APK must be exactly the CI-built unsigned APK plus a signing
block, and `apksigcopier compare` (F-Droid's own tool) must accept it. So a
build that can't be reproduced is caught before publishing.

Reproducibility has been tested: v0.1.3 was built from its tag in the normal
local environment (Arch Linux, OpenJDK 17.0.20.1) and in a clean
`eclipse-temurin:17-jdk` container (Ubuntu, freshly installed Android SDK,
empty Gradle cache, checkout at GitHub's runner path), and again in an older
`eclipse-temurin:17.0.12_7-jdk` container. All three unsigned APKs were
byte-identical, and the published v0.1.3 is exactly that APK plus its signing
block.

## One-time setup

Local tools:

- JDK 17 and a working Gradle build, since the release APK is built locally;
  Android SDK with `build-tools;35.0.0` for the APK checks (`sdk.dir` in
  `local.properties` or `ANDROID_HOME`)
- `gh` (logged in with an account that can create releases), `git`, `jq`,
  `python3`, `curl`
- `apksigcopier`: `pipx install apksigcopier` (or set `APKSIGCOPIER=/path/to/it`)
- the existing untracked `keystore.properties` and keystore, unchanged. The
  publish script copies `keystore.properties` into a private temporary clone
  for the build (making a relative `storeFile` absolute) and deletes it
  afterwards.

Repository settings are listed in the [checklist below](#repository-settings-checklist).
None of them have been applied.

## Releasing version X.Y.Z

1. **Prepare the release commit** on a branch or on `main`:
   - bump `versionCode` (+1) and `versionName` in `app/build.gradle.kts`;
   - add `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt`,
     starting with `X.Y.Z - ` (500 characters max);
   - add `.github/release-notes/vX.Y.Z.md` (start from `TEMPLATE.md`),
     including credits.
2. **Run the local preflight:**
   ```bash
   scripts/release-preflight.sh X.Y.Z           # metadata + GitHub checks
   scripts/release-preflight.sh X.Y.Z --build   # also tests, lint-vital, unsigned build (clean tree)
   ```
3. **Push to `main`** and run **Actions → Release preflight → Run workflow**
   (branch `main`, version `X.Y.Z`). This runs every check the tag-triggered
   workflow runs, apart from the tag itself. The run summary shows the commit
   to tag.
4. **Tag exactly that commit** with an annotated tag and push the tag:
   ```bash
   git tag -a vX.Y.Z <commit> -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```
5. **Wait for the Release workflow** (Actions → Release, run for `vX.Y.Z`) to
   succeed.
6. **Build, sign and publish** from your machine:
   ```bash
   scripts/release/publish-release.sh vX.Y.Z --dry-run   # optional: review build/release/vX.Y.Z/
   rm -rf build/release/vX.Y.Z                           # only after a dry run
   scripts/release/publish-release.sh vX.Y.Z
   ```
   It clones exactly the tagged commit into a private temporary directory and
   runs `./gradlew --no-daemon assembleRelease` there with a temporary
   `keystore.properties`. It requires the signed result to match the CI
   artifact exactly. Then it shows a summary, asks you to type the tag, creates a draft release,
   checks the uploaded asset's digest, publishes the draft, and re-downloads
   the public asset to confirm its SHA-256. The signed APK, unsigned APK,
   manifest and rendered notes stay in `build/release/vX.Y.Z/`.

## What is checked where

| Check | Local preflight | Preflight workflow | Release workflow | publish-release.sh |
|---|:-:|:-:|:-:|:-:|
| versionName matches version; one versionCode/versionName | ✓ | ✓ | ✓ | ✓ (tagged commit) |
| Fastlane changelog exists, `X.Y.Z - ` prefix, ≤ 500 chars, versionCode bumped | ✓ | ✓ | ✓ | ✓ |
| Release notes present and valid, no placeholders, no `## This build` | ✓ | ✓ | ✓ | ✓ |
| No signing material tracked in git | ✓ | ✓ | ✓ | ✓ |
| No release exists for the tag | ✓ | ✓ | ✓ | ✓ (incl. drafts, re-checked before creating) |
| Tag doesn't exist yet | ✓ | ✓ | – | – |
| Version and versionCode above latest release; latest release has the pinned certificate | ✓ | ✓ | ✓ | ✓ |
| Commit is on `main` | ✓ (if pushed) | ✓ | ✓ | ✓ |
| Tag is annotated and points at the built commit | – | – | ✓ | ✓ (plus matches your local tag, re-checked after publishing) |
| Gradle wrapper validation | – | ✓ | ✓ | – |
| `testReleaseUnitTest`, `lintVitalRelease`, `assembleRelease` (unsigned) | `--build` | ✓ | ✓ | – |
| Unsigned APK: package, version, minSdk ≥ 24, not debuggable, permission allow-list (no `INTERNET`), aligned, no signing block | `--build` | ✓ | ✓ | ✓ |
| Exactly one successful `release.yml` push run for the tag and commit | – | – | – | ✓ |
| Artifact `release-unsigned-X.Y.Z`: single, unexpired, GitHub digest matches, exactly two files | – | – | – | ✓ |
| Manifest: strict schema, every verifiable field matches | – | – | – | ✓ |
| Local Gradle release build of exactly the tagged commit (clean clone), signed by AGP | – | – | – | ✓ |
| Signed APK: one signer with the pinned certificate, v2 only, no extra signing-block entries (so no dependency-info block), no apksigner warnings | – | – | – | ✓ |
| Local signed APK = CI unsigned APK + signing block, byte for byte, no padding; `apksigcopier compare` against the CI APK | – | – | – | ✓ |
| Uploaded asset digest before publishing; public download hash after | – | – | – | ✓ |

## When something fails

- **Before tagging:** fix it, push, and run the preflight again. Nothing has
  been used up.
- **Release workflow, transient failure** (network, runner): re-run the
  workflow from the Actions tab. The tag is unchanged. If there are then
  several successful runs, pass `--run-id` to the publish script.
- **Release workflow, content failure** (the tagged commit is wrong): the tag
  can't be fixed. Leave it, fix `main`, and release the next version (X.Y.Z+1).
  Don't delete or move the tag; F-Droid may already have seen it.
- **Artifact expired** (30 days): re-run the Release workflow for the tag.
- **publish-release.sh fails before creating the release:** nothing was
  published. Fix the cause, remove `build/release/vX.Y.Z`, and run it again.
- **Local build doesn't match CI** ("local build does not match the CI
  artifact"): nothing was signed or published, and there is intentionally no
  other way to sign. Find the difference first: compare
  `build/release/vX.Y.Z/0x56erify-X.Y.Z-unsigned.apk` with a local unsigned
  build of the tag, using `unzip -l` / `diffoscope`. Typical causes are a
  different JDK or a changed dependency. The same difference would most likely
  make F-Droid reject the release too.
- **publish-release.sh fails after creating the draft:** the draft is left
  unpublished, so it isn't visible to users or F-Droid. The error tells you how
  to delete it (`gh release delete vX.Y.Z` doesn't delete the tag).

## Security model and known limits

- **CI is read-only.** Every workflow sets `permissions: {}` at the top and
  grants only `contents: read` to the job. Actions are pinned to full commit
  SHAs, there are no caches, and checkout uses `persist-credentials: false`.
  Workflow inputs reach scripts only through environment variables.
- **Two independent builds.** The published APK is built on your machine and
  must equal, byte for byte, the unsigned APK from the `release.yml` run for
  this tag and commit (GitHub's artifact digest plus cross-checked manifest
  fields). A compromise that affects only one environment is caught. F-Droid
  rebuilds from source as a third, independent check. A compromised dependency
  served identically to both environments would not be caught; Gradle
  dependency verification (`gradle/verification-metadata.xml`) isn't enabled
  yet and is a candidate for future hardening.
- **Manifest trust.** Changes after upload are caught by GitHub's artifact
  digest. Every manifest field that can be checked independently is: tag, tag
  object, commit, run, workflow, version, versionCode and APK hash. The
  unit-test counts (shown in the release notes) are reported by the run itself,
  so they're only as trustworthy as the workflow at the tagged commit.
- **Signing key handling.** As for every earlier release, the key is available
  to the local Gradle build, including its plugins and dependencies. The
  temporary `keystore.properties` exists only inside a private (mode 700)
  temporary clone for the duration of one `--no-daemon` build. Key values are
  never printed or passed on a command line.

## Testing the release tooling

`scripts/release/tests/run.sh` checks the fail-closed behaviour of these
scripts offline, with a throwaway key and a mocked GitHub. `--full` adds one
real Gradle-signed dry run. See
[`scripts/release/tests/README.md`](../scripts/release/tests/README.md). Run it
after changing anything under `scripts/release/`.

## Later: signing in GitHub, provenance

- **Signing in a protected environment:** `build-signed-release.sh` already
  accepts the key via `RELEASE_KEYSTORE_FILE`, `RELEASE_KEY_ALIAS`,
  `RELEASE_KEYSTORE_PASSWORD` and `RELEASE_KEY_PASSWORD`. To move signing to
  GitHub:
  - add a `sign` job in a `release` environment (required reviewer, `v*` tags
    only) that decodes the keystore into `$RUNNER_TEMP` and calls the script
    against the unsigned-build job's artifact;
  - add a `publish` job with `contents: write` that runs the non-interactive
    part of `publish-release.sh`.
  
  Keeping the Gradle signing path means that job runs a Gradle build with the
  secrets available. Its second build would also no longer be on an
  independent machine.
- **Build provenance:** `actions/attest-build-provenance` can be added to the
  Release workflow later. It needs `id-token: write` and `attestations: write`
  in that job. `publish-release.sh` would then run
  `gh attestation verify --repo 0x56dev/0x56erify` on the unsigned APK. The
  manifest carries a `schema` number for exactly this kind of change.

## Repository settings checklist

Proposed only; nothing has been applied. Apply them in
**Settings → Rules → Rulesets** and **Settings → Actions → General**, or with
the `gh api` commands shown.

### 1. Ruleset: release tags are immutable (no bypass)

Nobody, including admins, can move, force-update or delete a `v*` tag while
this ruleset is active. Disabling it is an explicit, audited settings change.

```json
{
  "name": "Release tags are immutable",
  "target": "tag",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/tags/v*"], "exclude": [] } },
  "rules": [
    { "type": "update" },
    { "type": "non_fast_forward" },
    { "type": "deletion" }
  ],
  "bypass_actors": []
}
```

### 2. Ruleset: only admins create release tags

A separate ruleset, because a bypass actor would otherwise also bypass the
immutability rules above.

```json
{
  "name": "Only admins create release tags",
  "target": "tag",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/tags/v*"], "exclude": [] } },
  "rules": [ { "type": "creation" } ],
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }
  ]
}
```

(`actor_id` 5 is the built-in *Repository admin* role.) To apply, save each
JSON to a file and run
`gh api -X POST repos/0x56dev/0x56erify/rulesets --input <file>`.

Afterwards, check:
- as admin, `git push origin <new v* tag>` works;
- `git push --force origin <existing v* tag>` and
  `git push origin :refs/tags/<existing tag>` are rejected;
- **Settings → Rules → Insights** shows the evaluations.

### 3. Actions settings (optional, recommended)

- **Workflow permissions:** keep "Read repository contents" (already the
  default here) and leave "Allow GitHub Actions to create and approve pull
  requests" off.
- **Require actions to be pinned to a full-length commit SHA:** on (the
  workflows already comply).
- **Allowed actions:** "Allow 0x56dev, and select non-0x56dev, actions and
  reusable workflows", with `actions/checkout@*`, `actions/setup-java@*`,
  `actions/upload-artifact@*` and `gradle/actions/wrapper-validation@*`.
- No repository or environment secrets are needed.
