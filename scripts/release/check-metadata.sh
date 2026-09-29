#!/usr/bin/env bash
# Check release metadata for a version, before or after tagging.
#
#   check-metadata.sh --version 0.1.4 --mode preflight|release [--commit SHA] [--offline]
#
# Source checks (working tree, or --commit to read a specific commit):
#   - exactly one versionCode/versionName (F-Droid UpdateCheckData regexes);
#     versionName == version
#   - Fastlane changelog <versionCode>.txt exists, starts with "<version> - ",
#     and is within F-Droid's 500-character limit
#   - human-written release notes .github/release-notes/v<version>.md are valid
#   - keystore.properties / keystores are not tracked
# GitHub checks (skipped with --offline):
#   - no release (visible to this token) exists for the tag
#   - preflight: the tag does not exist yet
#   - the new version and versionCode are greater than the latest release's,
#     read from its published APK, which must carry the release certificate
#
# With --github-output FILE, writes version_code=<n> to FILE.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { die "usage: ${0##*/} --version X.Y.Z --mode preflight|release [--commit SHA] [--offline] [--github-output FILE]"; }

version="" mode="" offline=false gh_out=""
while (($#)); do
  case "$1" in
    --version) [[ $# -ge 2 ]] || usage; version="$2"; shift 2 ;;
    --mode)    [[ $# -ge 2 ]] || usage; mode="$2"; shift 2 ;;
    --commit)  [[ $# -ge 2 ]] || usage; SRC_COMMIT="$(git -C "$REPO_ROOT" rev-parse --verify "$2^{commit}")" \
                 || die "unknown commit $2"; shift 2 ;;
    --offline) offline=true; shift ;;
    --github-output) [[ $# -ge 2 ]] || usage; gh_out="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$version" ]] || usage
[[ "$mode" == preflight || "$mode" == release ]] || usage
validate_version "$version"
tag="v$version"
require_cmd python3 git

step "Release metadata for $tag ($mode, source: ${SRC_COMMIT:-working tree})"

# versionCode / versionName
read -r code name < <(gradle_version) || die "could not read version from $GRADLE_FILE"
[[ -n "${code:-}" && -n "${name:-}" ]] || die "could not read version from $GRADLE_FILE"
[[ "$name" == "$version" ]] || die "$GRADLE_FILE has versionName \"$name\", but the release is $version"
ok "$GRADLE_FILE: versionCode $code, versionName $name"

# Fastlane changelog
changelog="$CHANGELOG_DIR/$code.txt"
src_exists "$changelog" || die "missing Fastlane changelog $changelog for versionCode $code"
changelog_text="$(src_cat "$changelog")"
first_line="$(head -n1 <<<"$changelog_text")"
[[ "$first_line" == "$version - "?* ]] \
  || die "$changelog must start with '$version - <summary>' (got '$first_line')"
chars="$(python3 -c 'import sys; print(len(sys.stdin.read().rstrip("\n")))' <<<"$changelog_text")"
((chars <= 500)) || die "$changelog is $chars characters; F-Droid's limit is 500"
next="$CHANGELOG_DIR/$((code + 1)).txt"
src_exists "$next" && die "$next exists but the release versionCode is $code; did you forget to bump versionCode?"
ok "$changelog ($chars chars)"

# Release notes
notes="$NOTES_DIR/$tag.md"
src_exists "$notes" || die "missing release notes $notes (copy $NOTES_DIR/TEMPLATE.md; see $NOTES_DIR/README.md)"
notes_tmp="$(mktemp)"
trap 'rm -f "$notes_tmp"' EXIT
src_cat "$notes" >"$notes_tmp"
title="$(python3 "$RELEASE_TOOL" notes-check --name "$notes" "$version" "$notes_tmp" 2>&1)" \
  || die "${title#ERROR: }"
ok "$notes: \"$title\""

# No signing material tracked
if [[ -n "$SRC_COMMIT" ]]; then
  tracked_files="$(git -C "$REPO_ROOT" ls-tree -r --name-only "$SRC_COMMIT")"
else
  tracked_files="$(git -C "$REPO_ROOT" ls-files --cached)"
fi
tracked="$(printf '%s\n' "$tracked_files" \
  | grep -E '(^|/)keystore\.properties$|\.(jks|keystore|p12|pfx)$' || true)"
[[ -z "$tracked" ]] || die "signing material is tracked in git: $tracked"
ok "no signing material tracked"

if [[ -n "$gh_out" ]]; then
  printf 'version_code=%s\n' "$code" >>"$gh_out"
fi

if $offline; then
  note "--offline: skipped GitHub tag/release and upgrade checks"
  exit 0
fi

# GitHub state
require_cmd gh jq
step "GitHub state for $tag"
if release_exists "$tag"; then
  die "a GitHub release for $tag already exists; existing releases are never modified. Use a new version."
fi
ok "no existing release for $tag"
if [[ "$mode" == preflight ]]; then
  remote_tag_exists "$tag" \
    && die "tag $tag already exists on GitHub; a tagged version cannot be preflighted again. Use a new version."
  ok "tag $tag does not exist yet"
fi

# Upgrade path from the latest published release
load_build_tools
latest="$(gh_api_or_404 "repos/$REPO/releases/latest")" || die "could not find the latest GitHub release"
prev_tag="$(jq -r .tag_name <<<"$latest")"
validate_tag "$prev_tag"
prev_version="${prev_tag#v}"
version_gt "$version" "$prev_version" \
  || die "version $version is not greater than the latest release $prev_version"
asset_name="$APP_NAME-$prev_version.apk"
asset="$(jq -c --arg n "$asset_name" '[.assets[] | select(.name == $n)]' <<<"$latest")"
[[ "$(jq length <<<"$asset")" == 1 ]] || die "latest release $prev_tag has no single asset named $asset_name"
digest="$(jq -r '.[0].digest // ""' <<<"$asset")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "latest release asset $asset_name has no SHA-256 digest from GitHub"
dl="$(mktemp -d)"
trap 'rm -f "$notes_tmp"; rm -rf "$dl"' EXIT
gh release download "$prev_tag" -R "$REPO" -p "$asset_name" -D "$dl" >/dev/null \
  || die "could not download $asset_name from release $prev_tag"
[[ "sha256:$(sha256_of "$dl/$asset_name")" == "$digest" ]] \
  || die "downloaded $asset_name does not match GitHub's recorded digest"
prev_code="$("$AAPT2" dump badging "$dl/$asset_name" | sed -n "s/^package: .* versionCode='\([0-9]*\)'.*/\1/p")"
[[ "$prev_code" =~ ^[0-9]+$ ]] || die "could not read versionCode of $asset_name"
((code > prev_code)) || die "versionCode $code is not greater than the latest release's versionCode $prev_code ($prev_tag)"
prev_cert="$(apk_cert_sha256 "$dl/$asset_name")"
[[ "$prev_cert" == "$SIGNING_CERT_SHA256" ]] \
  || die "latest release $prev_tag is signed by $prev_cert, not the pinned release certificate; stop and investigate"
ok "upgrade from $prev_tag (versionCode $prev_code, release certificate) to $tag (versionCode $code)"
