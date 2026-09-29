#!/usr/bin/env bash
# CI steps for .github/workflows/_release-checks.yml. Not meant to be run locally.
#
#   ci.sh context   validate the trigger/inputs; export RELEASE_* to later steps
#   ci.sh sdk       install the pinned Android build-tools
#   ci.sh build     unit tests, lint-vital and the unsigned release build
#   ci.sh package   check the unsigned APK, write release-manifest.json into dist/

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ "${GITHUB_ACTIONS:-}" == "true" ]] || die "ci.sh only runs inside GitHub Actions; use scripts/release-preflight.sh locally"
require_cmd gh jq python3 git

ctx_context() {
  local mode="${INPUT_MODE:-}" version tag="" tag_obj="" head
  head="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  [[ "$head" == "$GITHUB_SHA" ]] || die "checked-out commit $head is not GITHUB_SHA $GITHUB_SHA"

  case "$mode" in
    preflight)
      [[ "$GITHUB_EVENT_NAME" == "workflow_dispatch" ]] || die "preflight mode must be started manually (event: $GITHUB_EVENT_NAME)"
      [[ -z "${INPUT_TAG:-}" ]] || die "preflight mode takes a version, not a tag"
      version="${INPUT_VERSION:-}"
      version="${version#"${version%%[![:space:]]*}"}"; version="${version%"${version##*[![:space:]]}"}"
      [[ "$version" != v* ]] || die "enter the version without the leading 'v' (e.g. 0.1.4)"
      validate_version "$version"
      ;;
    release)
      [[ "$GITHUB_EVENT_NAME" == "push" && "${GITHUB_REF_TYPE:-}" == "tag" ]] \
        || die "release mode only runs for pushed tags (event: $GITHUB_EVENT_NAME, ref type: ${GITHUB_REF_TYPE:-})"
      [[ -z "${INPUT_VERSION:-}" ]] || die "release mode derives the version from the tag"
      tag="${INPUT_TAG:-}"
      [[ "$tag" == "$GITHUB_REF_NAME" && "$GITHUB_REF" == "refs/tags/$tag" ]] \
        || die "tag input '$tag' does not match the pushed ref $GITHUB_REF"
      validate_tag "$tag"
      version="${tag#v}"
      step "Tag $tag"
      tag_obj="$(check_tag "$tag" "$GITHUB_SHA")"
      ok "annotated tag $tag (object $tag_obj) -> commit $GITHUB_SHA"
      ;;
    *) die "unknown mode '$mode'" ;;
  esac
  check_on_main "$GITHUB_SHA"

  {
    printf 'RELEASE_MODE=%s\n' "$mode"
    printf 'RELEASE_VERSION=%s\n' "$version"
    printf 'RELEASE_TAG=%s\n' "$tag"
    printf 'RELEASE_TAG_OBJECT=%s\n' "$tag_obj"
  } >>"$GITHUB_ENV"
  printf 'artifact_name=%s-unsigned-%s\n' "$mode" "$version" >>"$GITHUB_OUTPUT"
  ok "$mode checks for version $version at $GITHUB_SHA"
}

ctx_sdk() {
  local sdk sdkmanager
  sdk="$(find_sdk_dir)"
  sdkmanager="$sdk/cmdline-tools/latest/bin/sdkmanager"
  [[ -x "$sdkmanager" ]] || die "sdkmanager not found at $sdkmanager"
  "$sdkmanager" --install "build-tools;$BUILD_TOOLS_VERSION" </dev/null >/dev/null \
    || die "could not install Android build-tools $BUILD_TOOLS_VERSION (license not accepted?)"
  load_build_tools
  ok "Android build-tools $BUILD_TOOLS_VERSION"
}

ctx_build() {
  # CI must never sign: without keystore.properties the release build is unsigned.
  [[ ! -e "$REPO_ROOT/keystore.properties" ]] || die "keystore.properties present in CI checkout"
  [[ -z "${RELEASE_KEYSTORE_FILE:-}" ]] || die "signing variables must not be set in the build job"
  cd "$REPO_ROOT"
  ./gradlew --no-daemon --stacktrace testReleaseUnitTest lintVitalRelease assembleRelease
  [[ ! -e app/build/outputs/apk/release/app-release.apk ]] || die "Gradle produced a signed APK in CI"
}

# The step summary is Markdown; backticks in single-quoted formats are literal.
# shellcheck disable=SC2016
ctx_package() {
  : "${RELEASE_MODE:?} ${RELEASE_VERSION:?}"
  local code tests apk dist sha msha
  read -r code _ < <(gradle_version) || die "could not read versionCode"
  [[ -f "$REPO_ROOT/$UNSIGNED_APK_GRADLE_PATH" ]] || die "unsigned APK not found at $UNSIGNED_APK_GRADLE_PATH"

  tests="$(python3 "$RELEASE_TOOL" junit "$REPO_ROOT/$TEST_RESULTS_DIR")"
  ok "unit tests: $tests"

  dist="$REPO_ROOT/dist"
  [[ ! -e "$dist" ]] || die "$dist already exists"
  mkdir -p "$dist"
  apk="$dist/$APP_NAME-$RELEASE_VERSION-unsigned.apk"
  cp -- "$REPO_ROOT/$UNSIGNED_APK_GRADLE_PATH" "$apk"
  "$RELEASE_DIR/check-apk.sh" --unsigned "$apk" --version "$RELEASE_VERSION" --code "$code"

  python3 "$RELEASE_TOOL" manifest-write \
    --mode "$RELEASE_MODE" --repository "$GITHUB_REPOSITORY" \
    --workflow-ref "$GITHUB_WORKFLOW_REF" \
    --run-id "$GITHUB_RUN_ID" --run-attempt "$GITHUB_RUN_ATTEMPT" \
    --ref "$GITHUB_REF" --tag "${RELEASE_TAG:-}" --tag-object "${RELEASE_TAG_OBJECT:-}" \
    --commit "$GITHUB_SHA" --package "$PACKAGE_NAME" \
    --version-name "$RELEASE_VERSION" --version-code "$code" \
    --apk "$apk" --unit-tests "$tests" --build-tools "$BUILD_TOOLS_VERSION" \
    --out "$dist/release-manifest.json"

  sha="$(sha256_of "$apk")"
  msha="$(sha256_of "$dist/release-manifest.json")"
  printf '\nrelease-manifest.json:\n' >&2
  cat "$dist/release-manifest.json" >&2
  ok "unsigned APK SHA-256 $sha"
  ok "manifest SHA-256 $msha"
  {
    printf '## %s build for %s\n\n' "${RELEASE_MODE^}" "${RELEASE_TAG:-v$RELEASE_VERSION (untagged)}"
    printf '| | |\n|---|---|\n'
    printf '| Commit | `%s` |\n' "$GITHUB_SHA"
    printf '| versionCode / versionName | %s / %s |\n' "$code" "$RELEASE_VERSION"
    printf '| Unit tests | `%s` |\n' "$tests"
    printf '| Unsigned APK | `%s` |\n' "$(basename "$apk")"
    printf '| Unsigned APK SHA-256 | `%s` |\n' "$sha"
    printf '| Manifest SHA-256 | `%s` |\n\n' "$msha"
    if [[ "$RELEASE_MODE" == preflight ]]; then
      printf 'Preflight passed. Tag **this exact commit** with an annotated tag:\n\n'
      printf '```\ngit tag -a v%s %s -m "v%s"\ngit push origin v%s\n```\n' \
        "$RELEASE_VERSION" "$GITHUB_SHA" "$RELEASE_VERSION" "$RELEASE_VERSION"
      printf '\nThis preflight artifact cannot be published.\n'
    else
      printf 'Next: `scripts/release/publish-release.sh %s` on your machine signs and publishes this artifact.\n' "$RELEASE_TAG"
    fi
  } >>"$GITHUB_STEP_SUMMARY"
}

case "${1:-}" in
  context) ctx_context ;;
  sdk)     ctx_sdk ;;
  build)   ctx_build ;;
  package) ctx_package ;;
  *) die "usage: ${0##*/} context|sdk|build|package" ;;
esac
