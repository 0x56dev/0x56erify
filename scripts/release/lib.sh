# shellcheck shell=bash
# Shared helpers for the release scripts. Source it; don't execute it.

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$RELEASE_DIR/../.." && pwd)"
RELEASE_TOOL="$RELEASE_DIR/release_tool.py"
# shellcheck source=scripts/release/release.conf
. "$RELEASE_DIR/release.conf"

# --- output ------------------------------------------------------------------

die() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    printf '::error::%s\n' "$*" >&2
  else
    printf '\nERROR: %s\n' "$*" >&2
  fi
  exit 1
}
step() { printf '\n==> %s\n' "$*" >&2; }
ok()   { printf '    ok: %s\n' "$*" >&2; }
note() { printf '    note: %s\n' "$*" >&2; }
warn() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    printf '::warning::%s\n' "$*" >&2
  else
    printf '    WARNING: %s\n' "$*" >&2
  fi
}

# Unexpected command failures still stop the script (set -e); say where. Errors
# raised with die() have already been explained, so this line is only context.
trap 'printf "    (stopped: %s line %s: %s)\n" "${0##*/}" "$LINENO" "$BASH_COMMAND" >&2' ERR

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command '$c' not found in PATH"
  done
}

# --- versions ------------------------------------------------------------------

validate_version() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "invalid version '$1': expected MAJOR.MINOR.PATCH, e.g. 0.1.4 (no leading 'v')"
}

validate_tag() {
  [[ "$1" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "invalid release tag '$1': expected vMAJOR.MINOR.PATCH, e.g. v0.1.4"
}

# version_gt A B: true if A > B (both MAJOR.MINOR.PATCH)
version_gt() {
  local -a a b
  local i
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for i in 0 1 2; do
    ((10#${a[i]} > 10#${b[i]})) && return 0
    ((10#${a[i]} < 10#${b[i]})) && return 1
  done
  return 1
}

# --- source access -------------------------------------------------------------
# With SRC_COMMIT set, repository files are read from that commit instead of the
# working tree, so checks see exactly what was tagged.

SRC_COMMIT="${SRC_COMMIT:-}"

src_exists() {
  if [[ -n "$SRC_COMMIT" ]]; then
    git -C "$REPO_ROOT" cat-file -e "$SRC_COMMIT:$1" 2>/dev/null
  else
    [[ -f "$REPO_ROOT/$1" ]]
  fi
}

src_cat() {
  if [[ -n "$SRC_COMMIT" ]]; then
    git -C "$REPO_ROOT" show "$SRC_COMMIT:$1"
  else
    cat "$REPO_ROOT/$1"
  fi
}

# Prints "<versionCode> <versionName>" using F-Droid's UpdateCheckData regexes.
gradle_version() {
  src_cat "$GRADLE_FILE" | python3 "$RELEASE_TOOL" gradle-version
}

# --- Android SDK tools -----------------------------------------------------------

find_sdk_dir() {
  local d="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -z "$d" && -f "$REPO_ROOT/local.properties" ]]; then
    d="$(sed -n 's/^sdk\.dir=//p' "$REPO_ROOT/local.properties" | tail -n1)"
  fi
  [[ -n "$d" && -d "$d" ]] \
    || die "Android SDK not found: set ANDROID_HOME or sdk.dir in local.properties"
  printf '%s\n' "$d"
}

# Sets AAPT2, APKSIGNER, ZIPALIGN for the pinned build-tools version.
load_build_tools() {
  local bt
  bt="$(find_sdk_dir)/build-tools/$BUILD_TOOLS_VERSION"
  [[ -d "$bt" ]] || die "Android build-tools $BUILD_TOOLS_VERSION not installed (expected $bt)"
  AAPT2="$bt/aapt2"; APKSIGNER="$bt/apksigner"; ZIPALIGN="$bt/zipalign"
  local t
  for t in "$AAPT2" "$APKSIGNER" "$ZIPALIGN"; do
    [[ -x "$t" ]] || die "missing build tool $t"
  done
}

sha256_of() {
  local out
  out="$(sha256sum -- "$1")" || die "cannot hash $1"
  printf '%s\n' "${out%% *}"
}

# Prints the SHA-256 of the single signer certificate of a signed APK.
apk_cert_sha256() {
  local out n cert
  out="$("$APKSIGNER" verify --print-certs -- "$1" 2>&1)" \
    || die "apksigner could not verify $1:"$'\n'"$out"
  n="$(grep -c '^Signer #[0-9]* certificate SHA-256 digest:' <<<"$out" || true)"
  [[ "$n" == 1 ]] || die "$1 has $n signer certificates, expected exactly 1"
  cert="$(sed -n 's/^Signer #1 certificate SHA-256 digest: //p' <<<"$out")"
  printf '%s\n' "$cert"
}

# --- GitHub ------------------------------------------------------------------------

# gh_api_or_404 PATH: prints the JSON body; returns 4 on HTTP 404, dies on other errors.
gh_api_or_404() {
  local out rc=0
  out="$(gh api -H 'Accept: application/vnd.github+json' "$1" 2>&1)" || rc=$?
  if ((rc == 0)); then
    printf '%s\n' "$out"
    return 0
  fi
  if grep -q 'HTTP 404' <<<"$out"; then
    return 4
  fi
  die "GitHub API request '$1' failed:"$'\n'"$out"
}

# check_on_main SHA: the commit must be contained in origin's main branch.
check_on_main() {
  local sha="$1" status
  status="$(gh api "repos/$REPO/compare/$sha...main" --jq .status)" \
    || die "could not compare $sha with main on GitHub (is the commit pushed?)"
  case "$status" in
    ahead|identical) ok "commit $sha is on main" ;;
    *) die "commit $sha is not on main (GitHub compare status: $status); releases are tagged on main" ;;
  esac
}

# resolve_tag TAG: TAG must exist on GitHub as an annotated tag pointing
# directly at a commit. Prints "<tag object SHA> <commit SHA>".
resolve_tag() {
  local tag="$1" ref_json obj_type obj_sha tag_json target rc=0
  ref_json="$(gh_api_or_404 "repos/$REPO/git/ref/tags/$tag")" || rc=$?
  ((rc == 4)) && die "tag $tag does not exist on GitHub"
  ((rc == 0)) || exit "$rc"
  [[ "$(jq -r 'type' <<<"$ref_json")" == "object" ]] \
    || die "GitHub returned several refs for tag $tag (prefix match); refusing"
  [[ "$(jq -r .ref <<<"$ref_json")" == "refs/tags/$tag" ]] \
    || die "GitHub ref lookup for $tag returned $(jq -r .ref <<<"$ref_json")"
  obj_type="$(jq -r .object.type <<<"$ref_json")"
  obj_sha="$(jq -r .object.sha <<<"$ref_json")"
  [[ "$obj_type" == "tag" ]] \
    || die "tag $tag is a lightweight tag; releases require an annotated tag (git tag -a)"
  tag_json="$(gh api "repos/$REPO/git/tags/$obj_sha")" \
    || die "could not read tag object $obj_sha"
  [[ "$(jq -r .tag <<<"$tag_json")" == "$tag" ]] \
    || die "tag object $obj_sha is named '$(jq -r .tag <<<"$tag_json")', not $tag"
  [[ "$(jq -r .object.type <<<"$tag_json")" == "commit" ]] \
    || die "tag $tag does not point at a commit"
  target="$(jq -r .object.sha <<<"$tag_json")"
  [[ "$obj_sha" =~ ^[0-9a-f]{40}$ && "$target" =~ ^[0-9a-f]{40}$ ]] || die "malformed tag data for $tag"
  printf '%s %s\n' "$obj_sha" "$target"
}

# check_tag TAG SHA: like resolve_tag, and the tag must point at commit SHA.
# Prints the tag object SHA.
check_tag() {
  local tag="$1" sha="$2" resolved
  resolved="$(resolve_tag "$tag")" || exit 1
  [[ "${resolved#* }" == "$sha" ]] \
    || die "tag $tag points at ${resolved#* }, not the expected commit $sha"
  printf '%s\n' "${resolved%% *}"
}

# release_exists TAG: true if any release (including drafts visible to this
# token) uses TAG.
release_exists() {
  local tags
  tags="$(gh api --paginate "repos/$REPO/releases?per_page=100" --jq '.[].tag_name')" \
    || die "could not list GitHub releases"
  grep -Fxq -- "$1" <<<"$tags"
}

remote_tag_exists() {
  local refs
  refs="$(gh api "repos/$REPO/git/matching-refs/tags/$1" --jq '.[].ref')" \
    || die "could not query tags on GitHub"
  grep -Fxq -- "refs/tags/$1" <<<"$refs"
}
