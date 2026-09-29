#!/usr/bin/env bash
# Build and sign the release APK locally with Gradle - the same signing path
# as every release so far - and require it to match the CI-built unsigned APK.
#
#   build-signed-release.sh --commit SHA --ci-unsigned CI.apk --out OUT.apk \
#                           --version 0.1.4 --code 5
#
# 1. Clones the repository at exactly COMMIT into a private temporary directory.
# 2. Writes a temporary keystore.properties into that clone (see below) and runs
#    ./gradlew --no-daemon assembleRelease, so AGP signs the APK during
#    packaging exactly as for v0.1.0-v0.1.3. The temporary clone, including
#    the temporary keystore.properties, is deleted on exit.
# 3. Refuses the result unless ALL of these pass:
#    - check-apk.sh --signed (package/version/permissions, pinned certificate,
#      v2 only, no extra signing-block entries)
#    - the signed APK is byte-for-byte the CI unsigned APK plus an APK Signing
#      Block, with no padding (release_tool.py compare)
#    - apksigcopier compare against the CI unsigned APK (F-Droid's check)
#    There is no fallback: if the local and CI builds differ, nothing is signed
#    another way.
#
# Key source, in order:
#   1. RELEASE_KEYSTORE_FILE, RELEASE_KEY_ALIAS, RELEASE_KEYSTORE_PASSWORD and
#      RELEASE_KEY_PASSWORD environment variables (all four; reserved for a
#      future protected GitHub environment job), or
#   2. the untracked keystore.properties at the repository root, copied as-is
#      except that a relative storeFile is made absolute (Gradle resolves it
#      against app/).
# Key values are never printed or passed on a command line.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { die "usage: ${0##*/} --commit SHA --ci-unsigned CI.apk --out OUT.apk --version X.Y.Z --code N"; }

commit="" ci_unsigned="" out="" version="" code=""
while (($#)); do
  case "$1" in
    --commit)      [[ $# -ge 2 ]] || usage; commit="$2"; shift 2 ;;
    --ci-unsigned) [[ $# -ge 2 ]] || usage; ci_unsigned="$2"; shift 2 ;;
    --out)         [[ $# -ge 2 ]] || usage; out="$2"; shift 2 ;;
    --version)     [[ $# -ge 2 ]] || usage; version="$2"; shift 2 ;;
    --code)        [[ $# -ge 2 ]] || usage; code="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$commit" && -n "$ci_unsigned" && -n "$out" && -n "$version" && -n "$code" ]] || usage
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "--commit must be a full commit SHA"
[[ -f "$ci_unsigned" ]] || die "CI unsigned APK not found: $ci_unsigned"
[[ ! -e "$out" ]] || die "output $out already exists; refusing to overwrite"
git -C "$REPO_ROOT" cat-file -e "$commit^{commit}" 2>/dev/null || die "commit $commit is not available locally"
require_cmd git python3
load_build_tools
APKSIGCOPIER="${APKSIGCOPIER:-apksigcopier}"
command -v "$APKSIGCOPIER" >/dev/null 2>&1 \
  || die "apksigcopier not found (F-Droid's signature-copy tool, used to check F-Droid can reuse the signature). Install it, e.g. 'pipx install apksigcopier', or set APKSIGCOPIER=/path/to/apksigcopier"

"$RELEASE_DIR/check-apk.sh" --unsigned "$ci_unsigned" --version "$version" --code "$code"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"
src="$tmp/src"

# --- temporary keystore.properties -----------------------------------------------

umask 077
props_out="$tmp/keystore.properties"
if [[ -n "${RELEASE_KEYSTORE_FILE:-}" ]]; then
  for v in RELEASE_KEY_ALIAS RELEASE_KEYSTORE_PASSWORD RELEASE_KEY_PASSWORD; do
    [[ -n "${!v:-}" ]] || die "RELEASE_KEYSTORE_FILE is set but $v is not"
  done
  [[ "$RELEASE_KEYSTORE_FILE" == /* ]] || die "RELEASE_KEYSTORE_FILE must be an absolute path"
  # java.util.Properties.load(InputStream): ISO-8859-1, backslash escapes.
  python3 - "$props_out" <<'PY' || die "could not write the temporary keystore.properties"
import os, sys
def esc(v):
    if any(ord(c) > 126 or ord(c) < 32 for c in v):
        sys.exit("ERROR: signing values must be printable ASCII")
    v = v.replace("\\", "\\\\")
    return "\\" + v if v[:1] in (" ", "\t", "\f") else v
vals = {"storeFile": os.environ["RELEASE_KEYSTORE_FILE"],
        "storePassword": os.environ["RELEASE_KEYSTORE_PASSWORD"],
        "keyAlias": os.environ["RELEASE_KEY_ALIAS"],
        "keyPassword": os.environ["RELEASE_KEY_PASSWORD"]}
with open(sys.argv[1], "w", encoding="ascii") as f:
    for k, v in vals.items():
        f.write(f"{k}={esc(v)}\n")
PY
  ks_file="$RELEASE_KEYSTORE_FILE"
  key_source="RELEASE_KEYSTORE_* environment"
else
  props="${RELEASE_KEYSTORE_PROPERTIES:-$REPO_ROOT/keystore.properties}"
  [[ -f "$props" ]] || die "no signing key configured: $props not found and RELEASE_KEYSTORE_FILE not set"
  # Copy the file as-is (Gradle parses it exactly as before); only a relative
  # storeFile is rewritten to an absolute path, because the build runs in a
  # different directory.
  python3 - "$props" "$props_out" "$REPO_ROOT/app" <<'PY' || die "could not prepare keystore.properties"
import os, re, sys
src, dst, app_dir = sys.argv[1:]
lines = open(src, "rb").read().split(b"\n")
found = {k: 0 for k in (b"storeFile", b"storePassword", b"keyAlias", b"keyPassword")}
out = []
for line in lines:
    m = re.match(rb"^[ \t\f]*([A-Za-z]+)[ \t\f]*[=:][ \t\f]*(.*?)\r?$", line)
    if m and m.group(1) in found:
        found[m.group(1)] += 1
        if m.group(1) == b"storeFile":
            path = m.group(2)
            if b"\\" in path:
                sys.exit("ERROR: backslashes in storeFile are not supported")
            if not path.startswith(b"/"):
                line = b"storeFile=" + os.path.normpath(os.path.join(app_dir.encode(), path))
    out.append(line)
bad = [k.decode() for k, n in found.items() if n != 1]
if bad:
    sys.exit(f"ERROR: {src} must define each of storeFile, storePassword, keyAlias, keyPassword exactly once (problem: {', '.join(bad)})")
fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "wb") as f:
    f.write(b"\n".join(out))
PY
  ks_file="$(sed -n 's/^[[:space:]]*storeFile[[:space:]]*[=:][[:space:]]*//p' "$props_out")"
  key_source="$props"
fi
[[ -f "$ks_file" && -r "$ks_file" ]] || die "keystore not readable: $ks_file"
ok "signing key from $key_source"

# --- clean checkout of the tagged commit --------------------------------------------------

step "Local Gradle release build of $commit"
git clone --quiet --shared --no-checkout "$REPO_ROOT" "$src" || die "could not clone the repository"
git -C "$src" checkout --quiet --detach "$commit" || die "could not check out $commit"
[[ "$(git -C "$src" rev-parse HEAD)" == "$commit" ]] || die "clone is not at $commit"
[[ -z "$(git -C "$src" status --porcelain --ignored)" ]] || die "fresh clone is not clean"
[[ ! -e "$src/keystore.properties" ]] || die "tagged commit contains keystore.properties"
ok "clean checkout at $commit"

mv -- "$props_out" "$src/keystore.properties"
build_rc=0
(cd "$src" && ANDROID_HOME="$(find_sdk_dir)" ./gradlew --no-daemon --quiet assembleRelease) \
  >"$tmp/gradle.log" 2>&1 || build_rc=$?
rm -f -- "$src/keystore.properties"
((build_rc == 0)) || die "Gradle release build failed (exit $build_rc):"$'\n'"$(tail -n 30 "$tmp/gradle.log")"

signed="$src/app/build/outputs/apk/release/app-release.apk"
[[ -f "$signed" ]] || die "Gradle did not produce a signed release APK (is keystore.properties complete?)"
[[ ! -e "$src/$UNSIGNED_APK_GRADLE_PATH" ]] || die "Gradle produced an unsigned APK; signing config was not applied"
ok "Gradle-signed APK built"

# --- verify ----------------------------------------------------------------------

"$RELEASE_DIR/check-apk.sh" --signed "$signed" --version "$version" --code "$code"

step "Comparing the local Gradle-signed APK with the CI unsigned APK"
cmp_out="$(python3 "$RELEASE_TOOL" compare "$signed" "$ci_unsigned" 2>&1)" \
  || die "local build does not match the CI artifact; not signing another way. ${cmp_out#ERROR: }"
ok "$cmp_out"
sc_out="$(PATH="$(dirname "$APKSIGNER"):$PATH" "$APKSIGCOPIER" compare "$signed" --unsigned "$ci_unsigned" 2>&1)" \
  || die "apksigcopier compare failed: F-Droid could not copy this signature onto the unsigned build:"$'\n'"$sc_out"
ok "apksigcopier compare: signature can be copied onto the CI unsigned build"

cp -n -- "$signed" "$out"
cmp -s -- "$signed" "$out" || die "could not copy signed APK to $out"
sha="$(sha256_of "$out")"
ok "signed APK $out"
ok "SHA-256 $sha"
printf '%s\n' "$sha"
