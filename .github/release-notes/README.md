# Release notes

Every GitHub release uses a human-written notes file from this directory,
committed **before** the release is tagged:

```
.github/release-notes/v<version>.md      e.g. v0.1.4.md
```

The notes are published exactly as written, so credits (for example
"Thanks to volunteer tester [@name](https://github.com/name) for reporting
this.") are never replaced by auto-generated notes. GitHub's
`--generate-notes` is never used.

## Format

```markdown
# v0.1.4 - Short release title

One or two sentences summarising the release.

## Fixed
- ...

Thanks to ... for reporting this.
```

- Line 1 must be `# v<version> - <title>`. It becomes the release title
  (`v0.1.4 - Short release title`) and is not repeated in the body.
- Line 2 must be blank; the rest is the body and must not be empty.
- Don't write a `## This build` section. `scripts/release/publish-release.sh`
  appends it with values measured by CI and the signing step: unit-test count,
  lint result, CI run link, signing certificate, versionCode/versionName and
  the APK SHA-256.
- Placeholder or template text (`TODO`, `TBD`, `FIXME`, `XXX`, HTML comments,
  empty links) is rejected, so an unedited copy of `TEMPLATE.md` can't be
  published.
- Do include things CI can't know, such as "Verified manually on a physical
  device".

The release checks (`scripts/release-preflight.sh`, the manual *Release
preflight* workflow and the tag-triggered *Release* workflow) validate the
file. Once the version is tagged, the notes in the tagged commit are the ones
published. Fix typos before tagging; after publishing, the release text can
still be edited by hand on GitHub.

The Fastlane changelog (`fastlane/metadata/android/en-US/changelogs/<versionCode>.txt`)
is separate: it's the short text F-Droid shows (500 characters max) and is
also required and checked for every release.
