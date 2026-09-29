#!/usr/bin/env bash
# Build and sign the release APK for an existing release tag locally with
# Gradle (the same signing path as every earlier release), require it to match
# the CI-built unsigned APK exactly, and publish it as the tag's GitHub release.
#
#   scripts/release/publish-release.sh v0.1.4 [--run-id ID] [--dry-run]
#
# Refuses (fails closed) unless ALL of these hold:
#   - the tag exists on GitHub as an annotated tag on main, and any local tag of
#     the same name is the same tag object
#   - the tagged commit's metadata passes check-metadata.sh (versionName/Code,
#     Fastlane changelog, release notes, upgrade from the latest release)
#   - no release (including drafts) exists for the tag
#   - exactly one successful push run of release.yml exists for the tag and
#     commit (or --run-id names one), and its single, unexpired artifact
#     release-unsigned-<version> matches GitHub's recorded digest and contains
#     exactly the unsigned APK and release-manifest.json
#   - every manifest field matches independently checked values
#   - the CI unsigned APK passes check-apk.sh
#   - a local Gradle release build of exactly the tagged commit, signed by AGP
#     with the key from keystore.properties, passes check-apk.sh (release
#     certificate, v2 only, package/version/permissions), is byte-for-byte the
#     CI unsigned APK plus a signing block (no padding), and passes
#     apksigcopier compare. There is no fallback signing method.
# Then, after you type the tag to confirm, it creates a DRAFT release, verifies
# the uploaded asset's digest, publishes the draft, and re-downloads the public
# asset to confirm its SHA-256. It never creates, moves or deletes tags and
# never edits an existing release.
#
# --dry-run does everything (including the local signed build) up to, not
# including, creating the release, and leaves the signed APK and rendered notes
# in build/release/<tag>/ for review.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { die "usage: ${0##*/} vX.Y.Z [--run-id ID] [--dry-run]"; }

tag="" run_id="" dry_run=false
while (($#)); do
  case "$1" in
    --run-id)  [[ $# -ge 2 ]] || usage; run_id="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -*) usage ;;
    *) [[ -z "$tag" ]] || usage; tag="$1"; shift ;;
  esac
done
[[ -n "$tag" ]] || usage
validate_tag "$tag"
version="${tag#v}"
[[ -z "$run_id" || "$run_id" =~ ^[1-9][0-9]*$ ]] || die "invalid --run-id '$run_id'"
require_cmd gh jq git python3 curl sha256sum
gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run 'gh auth login'"
load_build_tools

out_dir="$REPO_ROOT/build/release/$tag"
[[ ! -e "$out_dir" ]] || die "$out_dir already exists from an earlier attempt; inspect it, then remove it to retry"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

apk_name="$APP_NAME-$version.apk"
unsigned_name="$APP_NAME-$version-unsigned.apk"
artifact_name="release-unsigned-$version"

# --- 1. tag -------------------------------------------------------------------------

step "1/7 Tag $tag"
read -r tag_obj commit < <(resolve_tag "$tag") || die "could not resolve tag $tag"
ok "annotated tag $tag (object $tag_obj) -> commit $commit"
if git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  local_obj="$(git -C "$REPO_ROOT" rev-parse "refs/tags/$tag")"
  [[ "$local_obj" == "$tag_obj" ]] \
    || die "your local tag $tag ($local_obj) differs from GitHub's ($tag_obj); investigate before releasing"
  ok "local tag $tag matches GitHub"
fi
if ! git -C "$REPO_ROOT" cat-file -e "$commit^{commit}" 2>/dev/null; then
  # Fetch into FETCH_HEAD only: no local refs or tags are created or changed.
  git -C "$REPO_ROOT" fetch --quiet --no-tags origin "refs/tags/$tag" \
    || die "could not fetch $tag from origin"
  [[ "$(git -C "$REPO_ROOT" rev-parse FETCH_HEAD)" == "$tag_obj" ]] \
    || die "fetched $tag does not match GitHub API's tag object"
fi
[[ "$(git -C "$REPO_ROOT" rev-parse "$tag_obj^{commit}" 2>/dev/null || true)" == "$commit" ]] \
  || die "local git data for $tag does not match GitHub"
check_on_main "$commit"

# --- 2. metadata at the tagged commit -----------------------------------------------

step "2/7 Metadata at $commit"
"$RELEASE_DIR/check-metadata.sh" --version "$version" --mode release --commit "$commit"
SRC_COMMIT="$commit"
read -r code _ < <(gradle_version) || die "could not read versionCode at $commit"
notes_src="$work/notes.md"
src_cat "$NOTES_DIR/$tag.md" >"$notes_src"

# --- 3. CI run --------------------------------------------------------------------------

step "3/7 CI run of $RELEASE_WORKFLOW_PATH for $tag"
if [[ -z "$run_id" ]]; then
  runs="$(gh api "repos/$REPO/actions/workflows/$(basename "$RELEASE_WORKFLOW_PATH")/runs?event=push&status=success&head_sha=$commit&per_page=100" \
    --jq "[.workflow_runs[] | select(.head_branch == \"$tag\") | .id]")" \
    || die "could not list $RELEASE_WORKFLOW_PATH runs"
  n="$(jq length <<<"$runs")"
  ((n > 0)) || die "no successful $RELEASE_WORKFLOW_PATH run for $tag at $commit; wait for it to finish (or fix and re-run it)"
  ((n == 1)) || die "$n successful runs for $tag; choose one with --run-id ($(jq -r 'join(", ")' <<<"$runs"))"
  run_id="$(jq -r '.[0]' <<<"$runs")"
fi
run="$(gh api "repos/$REPO/actions/runs/$run_id")" || die "could not read run $run_id"
check_run_field() {
  local got
  got="$(jq -r "$1" <<<"$run")"
  [[ "$got" == "$2" ]] || die "run $run_id: $1 is '$got', expected '$2'"
}
check_run_field .path "$RELEASE_WORKFLOW_PATH"
check_run_field .event push
check_run_field .head_branch "$tag"
check_run_field .head_sha "$commit"
check_run_field .status completed
check_run_field .conclusion success
check_run_field .repository.full_name "$REPO"
check_run_field .head_repository.full_name "$REPO"
run_attempt="$(jq -r .run_attempt <<<"$run")"
run_url="$(jq -r .html_url <<<"$run")"
ok "run $run_id (attempt $run_attempt) succeeded: $run_url"

# --- 4. artifact + manifest ---------------------------------------------------------------

step "4/7 Artifact $artifact_name"
arts="$(gh api "repos/$REPO/actions/runs/$run_id/artifacts?per_page=100" \
  --jq "[.artifacts[] | select(.name == \"$artifact_name\")]")" || die "could not list artifacts of run $run_id"
[[ "$(jq length <<<"$arts")" == 1 ]] \
  || die "run $run_id has $(jq length <<<"$arts") artifacts named $artifact_name, expected exactly 1"
art="$(jq '.[0]' <<<"$arts")"
[[ "$(jq -r .expired <<<"$art")" == false ]] \
  || die "artifact $artifact_name has expired; re-run the Release workflow for $tag to rebuild it"
[[ "$(jq -r .workflow_run.id <<<"$art")" == "$run_id" && "$(jq -r .workflow_run.head_sha <<<"$art")" == "$commit" ]] \
  || die "artifact $artifact_name does not belong to run $run_id at $commit"
art_digest="$(jq -r '.digest // ""' <<<"$art")"
[[ "$art_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "artifact $artifact_name has no SHA-256 digest recorded by GitHub"
gh api "repos/$REPO/actions/artifacts/$(jq -r .id <<<"$art")/zip" >"$work/artifact.zip" \
  || die "could not download artifact $artifact_name"
[[ "sha256:$(sha256_of "$work/artifact.zip")" == "$art_digest" ]] \
  || die "downloaded artifact does not match GitHub's recorded digest $art_digest"
ok "artifact digest $art_digest"
mkdir "$work/artifact"
python3 - "$work/artifact.zip" "$work/artifact" "$unsigned_name" <<'PY' || die "artifact contents are not as expected"
import sys, zipfile, os
zpath, dest, apk = sys.argv[1:]
expected = {apk, "release-manifest.json"}
with zipfile.ZipFile(zpath) as z:
    names = [i.filename for i in z.infolist()]
    if sorted(names) != sorted(expected):
        sys.exit(f"ERROR: artifact contains {sorted(names)}, expected exactly {sorted(expected)}")
    for n in names:
        with z.open(n) as src, open(os.path.join(dest, n), "xb") as dst:
            dst.write(src.read())
PY
unsigned="$work/artifact/$unsigned_name"
manifest="$work/artifact/release-manifest.json"
unsigned_sha="$(sha256_of "$unsigned")"

tests="$(python3 "$RELEASE_TOOL" manifest-check "$manifest" \
  --expect "mode=release" \
  --expect "repository=$REPO" \
  --expect "workflow_ref=$REPO/$RELEASE_WORKFLOW_PATH@refs/tags/$tag" \
  --expect "run_id=$run_id" \
  --expect "ref=refs/tags/$tag" \
  --expect "tag=$tag" \
  --expect "tag_object=$tag_obj" \
  --expect "commit=$commit" \
  --expect "package=$PACKAGE_NAME" \
  --expect "version_name=$version" \
  --expect "version_code=$code" \
  --expect "unsigned_apk=$unsigned_name" \
  --expect "unsigned_apk_sha256=$unsigned_sha" \
  --expect "lint_task=lintVitalRelease" \
  --expect "build_tools=$BUILD_TOOLS_VERSION" 2>&1)" || die "manifest check failed: ${tests#ERROR: }"
m_attempt="$(jq -r .run_attempt "$manifest")"
((m_attempt >= 1 && m_attempt <= run_attempt)) || die "manifest run_attempt $m_attempt is not an attempt of run $run_id"
ok "manifest matches tag, commit, run, version and APK hash; unit tests $tests"
"$RELEASE_DIR/check-apk.sh" --unsigned "$unsigned" --version "$version" --code "$code"

# --- 5. sign ----------------------------------------------------------------------------------

step "5/7 Local Gradle release build and signing"
mkdir -p "$out_dir"
chmod 700 "$out_dir"
signed="$out_dir/$apk_name"
apk_sha="$("$RELEASE_DIR/build-signed-release.sh" --commit "$commit" --ci-unsigned "$unsigned" \
  --out "$signed" --version "$version" --code "$code")" || die "local signed build failed; nothing was published"
[[ "$apk_sha" =~ ^[0-9a-f]{64}$ && "$(sha256_of "$signed")" == "$apk_sha" ]] || die "signed APK hash mismatch"
cp -- "$unsigned" "$manifest" "$out_dir/"

# --- 6. notes -----------------------------------------------------------------------------------

step "6/7 Release notes"
python3 "$RELEASE_TOOL" notes-render --version "$version" --version-code "$code" \
  --notes "$notes_src" --tag "$tag" --commit "$commit" --run-id "$run_id" --run-url "$run_url" \
  --unit-tests "$tests" --cert "$SIGNING_CERT_SHA256" --apk-sha256 "$apk_sha" \
  --title-out "$out_dir/release-title.txt" --body-out "$out_dir/release-notes.md"
title="$(<"$out_dir/release-title.txt")"
ok "title: $title"
ok "notes: $out_dir/release-notes.md"

cat >&2 <<EOF

------------------------------------------------------------------------
  Release   $title
  Tag       $tag  (object $tag_obj)
  Commit    $commit
  CI run    $run_url
  Version   $version (versionCode $code)
  APK       $signed
  SHA-256   $apk_sha
  Cert      $SIGNING_CERT_SHA256
------------------------------------------------------------------------
EOF

if $dry_run; then
  step "Dry run: stopping before creating the release"
  note "review $out_dir/release-notes.md; remove $out_dir before the real run"
  exit 0
fi

[[ -r /dev/tty ]] || die "confirmation needs an interactive terminal"
printf '\nPublish this release? Type the tag (%s) to confirm: ' "$tag" >/dev/tty
read -r answer </dev/tty || die "no confirmation"
[[ "$answer" == "$tag" ]] || die "confirmation did not match; nothing was published"

# --- 7. publish ---------------------------------------------------------------------------------

step "7/7 Publish"
# Re-check what might have changed while we worked.
[[ "$(check_tag "$tag" "$commit")" == "$tag_obj" ]] || die "tag $tag changed during the release"
release_exists "$tag" && die "a release for $tag appeared during the run; not touching it"

gh release create "$tag" "$signed" -R "$REPO" --verify-tag --draft \
  --title "$title" --notes-file "$out_dir/release-notes.md" >/dev/null \
  || die "gh release create failed; check for a partial draft with: gh release list -R $REPO"

left_draft() {
  die "$1. The DRAFT release was left unpublished for inspection; delete it with 'gh release delete $tag -R $REPO' (this does not delete the tag), remove $out_dir, and retry."
}
rel="$(gh api --paginate "repos/$REPO/releases?per_page=100" \
  --jq "[.[] | select(.tag_name == \"$tag\")]" | jq -s 'add')" || left_draft "could not read back the draft"
[[ "$(jq length <<<"$rel")" == 1 ]] || left_draft "expected exactly one release for $tag"
rel="$(jq '.[0]' <<<"$rel")"
rel_id="$(jq -r .id <<<"$rel")"
[[ "$(jq -r .draft <<<"$rel")" == true ]] || left_draft "release for $tag is not a draft"
[[ "$(jq -r .name <<<"$rel")" == "$title" ]] || left_draft "draft title differs"
[[ "$(jq '.assets | length' <<<"$rel")" == 1 ]] || left_draft "draft does not have exactly one asset"
[[ "$(jq -r '.assets[0].name' <<<"$rel")" == "$apk_name" ]] || left_draft "draft asset is not named $apk_name"
[[ "$(jq -r '.assets[0].state' <<<"$rel")" == uploaded ]] || left_draft "draft asset upload is incomplete"
[[ "$(jq -r '.assets[0].digest // ""' <<<"$rel")" == "sha256:$apk_sha" ]] \
  || left_draft "uploaded asset digest does not match the signed APK"
ok "draft release $rel_id with $apk_name (sha256:$apk_sha)"

gh api -X PATCH "repos/$REPO/releases/$rel_id" -F draft=false >/dev/null \
  || left_draft "publishing the draft failed"

pub="$(gh api "repos/$REPO/releases/tags/$tag")" || die "published, but could not read the release back; check it manually"
[[ "$(jq -r .id <<<"$pub")" == "$rel_id" && "$(jq -r .draft <<<"$pub")" == false ]] \
  || die "release for $tag is not the published draft; check it manually"
url="https://github.com/$REPO/releases/download/$tag/$apk_name"
curl -fsSL --retry 3 -o "$work/public.apk" "$url" || die "published, but downloading $url failed; check it manually"
[[ "$(sha256_of "$work/public.apk")" == "$apk_sha" ]] \
  || die "PUBLISHED ASSET HASH MISMATCH at $url; investigate immediately"
[[ "$(check_tag "$tag" "$commit")" == "$tag_obj" ]] || die "tag $tag changed; investigate immediately"

ok "published $(jq -r .html_url <<<"$pub")"
ok "public asset $url"
ok "SHA-256 $apk_sha"
note "F-Droid fetches this URL (Binaries:) and compares it with its own build of $tag"
