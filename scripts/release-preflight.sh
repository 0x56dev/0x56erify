#!/usr/bin/env bash
# Local release preflight: run before pushing/tagging a release so a typo or
# metadata mistake is caught while it is still cheap to fix.
#
#   scripts/release-preflight.sh 0.1.4            metadata + GitHub checks (fast)
#   scripts/release-preflight.sh 0.1.4 --build    also tests, lint-vital and an
#                                                 unsigned release build of HEAD
#   scripts/release-preflight.sh 0.1.4 --offline  skip GitHub queries
#
# Without --build the working tree is checked (handy while editing notes).
# --build requires a clean tree and builds HEAD in a temporary clone, which has
# no keystore.properties and therefore produces the same unsigned APK as CI.
# The authoritative pre-tag check is the "Release preflight" workflow on main.

. "$(dirname "${BASH_SOURCE[0]}")/release/lib.sh"

usage() { die "usage: ${0##*/} X.Y.Z [--build] [--offline]"; }

version="" build=false offline=()
while (($#)); do
  case "$1" in
    --build) build=true; shift ;;
    --offline) offline=(--offline); shift ;;
    -*) usage ;;
    *) [[ -z "$version" ]] || usage; version="$1"; shift ;;
  esac
done
[[ -n "$version" ]] || usage
[[ "$version" != v* ]] || die "give the version without the leading 'v' (e.g. ${version#v})"
validate_version "$version"
require_cmd git python3

dirty="$(git -C "$REPO_ROOT" status --porcelain)"
commit_args=()
if $build; then
  [[ -z "$dirty" ]] || die "--build needs a clean working tree (commit or stash first):"$'\n'"$dirty"
  commit_args=(--commit HEAD)
elif [[ -n "$dirty" ]]; then
  warn "working tree has uncommitted changes; checking the working tree, but the tag will be of a commit"
fi

"$RELEASE_DIR/check-metadata.sh" --version "$version" --mode preflight "${commit_args[@]}" "${offline[@]}"

head="$(git -C "$REPO_ROOT" rev-parse HEAD)"
if ((${#offline[@]} == 0)); then
  require_cmd gh
  step "Commit"
  if gh api "repos/$REPO/commits/$head" --silent 2>/dev/null; then
    check_on_main "$head"
  else
    warn "HEAD $head is not on GitHub yet; push it to main before running the Release preflight workflow"
  fi
fi

if $build; then
  load_build_tools
  step "Unsigned release build of HEAD $head"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  git clone --quiet --shared --no-checkout "$REPO_ROOT" "$tmp/src"
  git -C "$tmp/src" checkout --quiet --detach "$head"
  [[ ! -e "$tmp/src/keystore.properties" ]] || die "keystore.properties unexpectedly present in clean clone"
  (cd "$tmp/src" && ANDROID_HOME="$(find_sdk_dir)" ./gradlew --no-daemon --quiet \
      testReleaseUnitTest lintVitalRelease assembleRelease) || die "Gradle build failed"
  tests="$(python3 "$RELEASE_TOOL" junit "$tmp/src/$TEST_RESULTS_DIR")"
  ok "unit tests: $tests"
  read -r code _ < <(SRC_COMMIT="$head" gradle_version)
  "$RELEASE_DIR/check-apk.sh" --unsigned "$tmp/src/$UNSIGNED_APK_GRADLE_PATH" --version "$version" --code "$code"
  ok "unsigned APK SHA-256 $(sha256_of "$tmp/src/$UNSIGNED_APK_GRADLE_PATH")"
fi

step "Local preflight passed for v$version"
note "next: push to main, run the 'Release preflight' workflow for $version, then tag the commit it reports"
