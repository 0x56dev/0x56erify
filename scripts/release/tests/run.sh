#!/usr/bin/env bash
# Release-tooling tests (separate from the app's Gradle unit tests).
#
#   scripts/release/tests/run.sh          fast suite: no network, no Gradle
#   scripts/release/tests/run.sh --full   also one real Gradle-signed dry run
#                                         of the app at HEAD (slow, a few minutes)
#
# Everything runs in a throwaway temporary directory, with a throwaway signing
# key, tiny APKs linked by aapt2 at test time (fixture/), and a mock of the few
# gh/curl calls the scripts make (mock/). Nothing touches GitHub, the real
# repository or the real release key.
#
# Requires: python3, jq, git, keytool, script (util-linux), apksigcopier, and
# an Android SDK (ANDROID_HOME or sdk.dir in local.properties) with the
# build-tools version from release.conf and at least one platform.
#
# The fast suite's stand-in gradlew signs with apksigner, which zero-pads
# before the signing block. To exercise the success path of the strict
# "signed == CI unsigned + signing block" check, the simulated CI artifact is
# therefore derived from the stand-in's signed output with only the signing
# block removed. --full checks the real AGP layout against a real unsigned
# Gradle build instead.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=scripts/release/release.conf
. "$HERE/../release.conf"

full=false
case "${1:-}" in
  "") ;;
  --full) full=true ;;
  *) echo "usage: ${0##*/} [--full]" >&2; exit 2 ;;
esac

for c in python3 jq git keytool script; do
  command -v "$c" >/dev/null || { echo "missing required command: $c" >&2; exit 2; }
done
APKSIGCOPIER="${APKSIGCOPIER:-$(command -v apksigcopier || true)}"
[[ -x "$APKSIGCOPIER" ]] || { echo "apksigcopier not found (pipx install apksigcopier, or set APKSIGCOPIER)" >&2; exit 2; }
export APKSIGCOPIER
if [[ -z "${ANDROID_HOME:-}" && -f "$SRC_ROOT/local.properties" ]]; then
  ANDROID_HOME="$(sed -n 's/^sdk\.dir=//p' "$SRC_ROOT/local.properties" | tail -n1)"
fi
[[ -d "${ANDROID_HOME:-}" ]] || { echo "Android SDK not found (set ANDROID_HOME)" >&2; exit 2; }
export ANDROID_HOME FIXTURE_BUILD_TOOLS="$BUILD_TOOLS_VERSION"
BT="$ANDROID_HOME/build-tools/$BUILD_TOOLS_VERSION"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp/tmp"  # scripts' own temp dirs land here, so leaks are detectable
mkdir -p "$TMPDIR"

pass=0 fail=0
# check NAME ok|fail PATTERN -- CMD...: CMD must succeed/fail and print PATTERN.
check() {
  local name="$1" want="$2" pat="$3" out rc=0
  shift 4
  out="$("$@" 2>&1)" || rc=$?
  if { [[ "$want" == ok ]] && ((rc == 0)); } || { [[ "$want" == fail ]] && ((rc != 0)); }; then
    if grep -qE -- "$pat" <<<"$out"; then
      pass=$((pass + 1)); printf '  PASS %s\n' "$name"; return
    fi
  fi
  fail=$((fail + 1))
  printf '  FAIL %s (exit %s, expected %s matching /%s/)\n' "$name" "$rc" "$want" "$pat"
  tail -n 8 <<<"$out" | sed 's/^/       /'
}
assert() { # assert NAME CMD...: CMD must succeed.
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); printf '  PASS %s\n' "$name"
  else fail=$((fail + 1)); printf '  FAIL %s\n' "$name"; fi
}

echo "== release_tool.py unit tests"
check unit-tests ok 'OK' -- python3 "$HERE/test_release_tool.py"

# --- throwaway key and fixture repository ------------------------------------------

keytool -genkeypair -storetype PKCS12 -keystore "$tmp/test.p12" -alias test -keyalg RSA \
  -keysize 2048 -validity 365 -dname CN=release-tooling-test \
  -storepass test-pass -keypass test-pass >/dev/null 2>&1
keytool -genkeypair -storetype PKCS12 -keystore "$tmp/other.p12" -alias other -keyalg RSA \
  -keysize 2048 -validity 365 -dname CN=other-key \
  -storepass test-pass -keypass test-pass >/dev/null 2>&1
test_cert="$(keytool -exportcert -keystore "$tmp/test.p12" -alias test -storepass test-pass \
  | sha256sum | cut -d' ' -f1)"

repo="$tmp/repo"
mkdir -p "$repo/scripts" "$repo/app" "$repo/$CHANGELOG_DIR" "$repo/$NOTES_DIR"
cp -r "$SRC_ROOT/scripts/release" "$repo/scripts/"
cp "$SRC_ROOT/scripts/release-preflight.sh" "$repo/scripts/"
cp "$HERE/fixture/gradlew" "$HERE/fixture/AndroidManifest.xml" "$repo/"
sed -i "s/^SIGNING_CERT_SHA256=.*/SIGNING_CERT_SHA256=\"$test_cert\"/" "$repo/scripts/release/release.conf"
printf 'keystore.properties\nbuild/\napp/build/\n' >"$repo/.gitignore"
printf 'storeFile=%s\nstorePassword=test-pass\nkeyAlias=test\nkeyPassword=test-pass\n' \
  "$tmp/test.p12" >"$repo/keystore.properties"
g() { git -C "$repo" -c user.name=test -c user.email=test@example.invalid "$@"; }
set_version() { # set_version CODE NAME: version files for a fixture release commit
  printf 'versionCode = %s\nversionName = "%s"\n' "$1" "$2" >"$repo/$GRADLE_FILE"
  printf '%s - Test release\n\n- Test change.\n' "$2" >"$repo/$CHANGELOG_DIR/$1.txt"
  printf '# v%s - Test release\n\nTest notes.\n\nThanks to [@tester](https://github.com/tester) for testing.\n' \
    "$2" >"$repo/$NOTES_DIR/v$2.md"
}
g init -q -b main
set_version 1 1.0.0
g add -A && g commit -qm "1.0.0"
(cd "$repo" && ./gradlew assembleRelease) && mv "$repo/app/build/outputs/apk/release/app-release.apk" "$tmp/prev.apk"
rm -rf "$repo/app/build"
set_version 2 1.0.1
g add -A && g commit -qm "1.0.1"
g tag -a v1.0.1 -m v1.0.1
commit="$(g rev-parse HEAD)" tag_obj="$(g rev-parse v1.0.1)"

# Signed build as the stand-in produces it, and the matching "CI" unsigned APK.
(cd "$repo" && ./gradlew assembleRelease)
mv "$repo/app/build/outputs/apk/release/app-release.apk" "$tmp/local-signed.apk"
rm -rf "$repo/app/build"
python3 - "$tmp/local-signed.apk" "$tmp/ci-unsigned.apk" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
eocd = d.rfind(b"PK\x05\x06"); cd = struct.unpack("<I", d[eocd + 16:eocd + 20])[0]
start = cd - (struct.unpack("<Q", d[cd - 24:cd - 16])[0] + 8)
tail = bytearray(d[eocd:]); struct.pack_into("<I", tail, 16, start)
open(sys.argv[2], "wb").write(d[:start] + d[cd:eocd] + bytes(tail))
PY
mv "$repo/keystore.properties" "$tmp/kp" && (cd "$repo" && ./gradlew assembleRelease) \
  && mv "$repo/app/build/outputs/apk/release/app-release-unsigned.apk" "$tmp/plain-unsigned.apk"
mv "$tmp/kp" "$repo/keystore.properties"; rm -rf "$repo/app/build"

export MOCK_DIR="$tmp/mock" MOCK_REPO="$REPO" MOCK_TAG=v1.0.1 MOCK_PREV_TAG=v1.0.0 \
  MOCK_COMMIT="$commit" MOCK_TAGOBJ="$tag_obj" MOCK_APP_NAME="$APP_NAME" MOCK_VERSION_CODE=2
mkdir -p "$MOCK_DIR"; cp "$tmp/prev.apk" "$MOCK_DIR/prev.apk"

# make_artifact APK [MANIFEST_EDIT_PY] [EXTRA_FILE]: writes $MOCK_DIR/artifact.zip
# as the Release workflow would for $MOCK_TAG, optionally tampered with.
make_artifact() {
  python3 - "$1" "$MOCK_DIR/artifact.zip" "${2:-}" "${3:-}" <<'PY'
import hashlib, json, os, sys, zipfile
apk, out, edit, extra = sys.argv[1:]
e = os.environ
tag, data = e["MOCK_TAG"], open(apk, "rb").read()
m = {"schema": 1, "mode": "release", "repository": e["MOCK_REPO"],
     "workflow_ref": f"{e['MOCK_REPO']}/{e['RELEASE_WORKFLOW_PATH']}@refs/tags/{tag}",
     "run_id": 1001, "run_attempt": 1, "ref": f"refs/tags/{tag}", "tag": tag,
     "tag_object": e["MOCK_TAGOBJ"], "commit": e["MOCK_COMMIT"], "package": e["PACKAGE_NAME"],
     "version_name": tag[1:], "version_code": int(e["MOCK_VERSION_CODE"]),
     "unsigned_apk": f"{e['MOCK_APP_NAME']}-{tag[1:]}-unsigned.apk",
     "unsigned_apk_sha256": hashlib.sha256(data).hexdigest(),
     "unit_tests": {"total": 3, "failures": 0, "errors": 0, "skipped": 0},
     "lint_task": "lintVitalRelease", "build_tools": e["BUILD_TOOLS_VERSION"]}
exec(edit)
stamp = (2020, 1, 1, 0, 0, 0)
with zipfile.ZipFile(out, "w") as z:
    z.writestr(zipfile.ZipInfo(m["unsigned_apk"], stamp), data)
    z.writestr(zipfile.ZipInfo("release-manifest.json", stamp), json.dumps(m))
    if extra:
        z.writestr(zipfile.ZipInfo(extra, stamp), b"x")
PY
}
export RELEASE_WORKFLOW_PATH PACKAGE_NAME BUILD_TOOLS_VERSION

# --- APK checks ---------------------------------------------------------------------

echo "== check-apk.sh"
variant() { # variant NAME SED_EXPR: unsigned tiny APK built from an edited manifest
  local d="$tmp/variant-$1"
  mkdir -p "$d/app" && cp "$repo/gradlew" "$d/" && cp "$repo/$GRADLE_FILE" "$d/app/"
  sed "$2" "$repo/AndroidManifest.xml" >"$d/AndroidManifest.xml"
  (cd "$d" && ./gradlew assembleRelease) && printf '%s\n' "$d/app/build/outputs/apk/release/app-release-unsigned.apk"
}
ck() { (cd "$repo" && scripts/release/check-apk.sh "$@"); }
check apk-unsigned-ok ok 'no APK Signing Block' -- ck --unsigned "$tmp/plain-unsigned.apk" --version 1.0.1 --code 2
check apk-signed-ok ok 'signed by release certificate' -- ck --signed "$tmp/local-signed.apk" --version 1.0.1 --code 2
check apk-wrong-version fail "versionCode is '2', expected '3'" -- ck --unsigned "$tmp/plain-unsigned.apk" --version 1.0.1 --code 3
check apk-unsigned-as-signed fail 'it is not signed' -- ck --signed "$tmp/plain-unsigned.apk" --version 1.0.1 --code 2
check apk-signed-as-unsigned fail 'unexpectedly has an APK Signing Block' -- ck --unsigned "$tmp/local-signed.apk" --version 1.0.1 --code 2
check apk-internet fail 'forbidden permission android.permission.INTERNET' -- ck --unsigned \
  "$(variant internet 's|<application />|<uses-permission android:name="android.permission.INTERNET" /><application />|')" --version 1.0.1 --code 2
check apk-unexpected-permission fail "unexpected permission 'android.permission.CAMERA'" -- ck --unsigned \
  "$(variant camera 's|<application />|<uses-permission android:name="android.permission.CAMERA" /><application />|')" --version 1.0.1 --code 2
check apk-debuggable fail 'debuggable' -- ck --unsigned \
  "$(variant debuggable 's|<application />|<application android:debuggable="true" />|')" --version 1.0.1 --code 2
check apk-wrong-package fail "package is 'com.example.other'" -- ck --unsigned \
  "$(variant package 's|package="dev.x56.verify"|package="com.example.other"|')" --version 1.0.1 --code 2
other_signed="$tmp/other-signed.apk"
KP=test-pass "$BT/apksigner" sign --ks "$tmp/other.p12" --ks-key-alias other --ks-pass env:KP --key-pass env:KP \
  --v1-signing-enabled false --v3-signing-enabled false --v4-signing-enabled false \
  --out "$other_signed" "$tmp/plain-unsigned.apk"
check apk-wrong-certificate fail 'expected the release certificate' -- ck --signed "$other_signed" --version 1.0.1 --code 2
v3_signed="$tmp/v3-signed.apk"
KP=test-pass "$BT/apksigner" sign --ks "$tmp/test.p12" --ks-key-alias test --ks-pass env:KP --key-pass env:KP \
  --v1-signing-enabled false --v3-signing-enabled true --v4-signing-enabled false \
  --out "$v3_signed" "$tmp/plain-unsigned.apk"
check apk-v3-signature fail 'unexpected entry 0xf05368c0' -- ck --signed "$v3_signed" --version 1.0.1 --code 2

# --- metadata / preflight -----------------------------------------------------------------

echo "== check-metadata.sh / release-preflight.sh"
pf() { (cd "$repo" && PATH="$HERE/mock:$PATH" scripts/release-preflight.sh "$@"); }
edit_check() { # edit_check NAME PATTERN SHELL_EDIT: edit the tree, expect preflight to fail, restore
  (cd "$repo" && eval "$3")
  check "$1" fail "$2" -- pf 1.0.1 --offline
  g checkout -q -- . && g clean -qfd -e keystore.properties
  g rm -q --cached --ignore-unmatch keystore.properties >/dev/null
}
make_artifact "$tmp/ci-unsigned.apk"
check preflight-offline-ok ok 'Local preflight passed' -- pf 1.0.1 --offline
check preflight-v-prefix fail "without the leading 'v'" -- pf v1.0.1 --offline
check metadata-release-mode-online ok 'upgrade from v1.0.0' -- \
  bash -c "cd '$repo' && PATH='$HERE/mock:$PATH' scripts/release/check-metadata.sh --version 1.0.1 --mode release --commit '$commit'"
edit_check notes-missing 'missing release notes' "rm $NOTES_DIR/v1.0.1.md"
edit_check notes-placeholder 'placeholder' "echo '- TODO' >>$NOTES_DIR/v1.0.1.md"
edit_check notes-reserved-heading 'generated by the release script' "printf '\n## This build\n- x\n' >>$NOTES_DIR/v1.0.1.md"
edit_check changelog-prefix "must start with '1.0.1 - " "sed -i '1s/.*/1.0.1: typo/' $CHANGELOG_DIR/2.txt"
edit_check changelog-too-long "F-Droid's limit is 500" "python3 -c \"print('1.0.1 - x ' + 'y' * 600)\" >$CHANGELOG_DIR/2.txt"
edit_check changelog-missing 'missing Fastlane changelog' "rm $CHANGELOG_DIR/2.txt"
edit_check version-name-mismatch 'versionName "1.0.2"' "sed -i 's/1.0.1/1.0.2/' $GRADLE_FILE"
edit_check version-code-duplicate 'exactly one' "echo '// versionCode = 9' >>$GRADLE_FILE"
edit_check keystore-tracked 'signing material is tracked' "git add -f keystore.properties"

# --- publish-release.sh ------------------------------------------------------------------

echo "== publish-release.sh (mock GitHub)"
reset() { rm -rf "$repo/build" "$MOCK_DIR/state.json" "$MOCK_DIR/uploaded.apk" "$MOCK_DIR/gh.log"; }
publish() { # publish SCENARIO [ARGS...]: dry run through the mock
  local sc="$1"; shift
  reset
  (cd "$repo" && PATH="$HERE/mock:$PATH" MOCK_SCENARIO="$sc" scripts/release/publish-release.sh v1.0.1 --dry-run "$@")
}
publish_confirm() { # publish_confirm SCENARIO ANSWER: real run, answering the confirmation prompt
  reset
  (cd "$repo" && (sleep 20; echo "$2") | PATH="$HERE/mock:$PATH" MOCK_SCENARIO="$1" \
    script -qec "scripts/release/publish-release.sh v1.0.1" /dev/null | tr -d '\r')
}
no_signed_output() { [[ ! -e "$repo/build/release/v1.0.1/$APP_NAME-1.0.1.apk" ]]; }
released() { # released DRAFT(true|false): the mock has exactly one v1.0.1 release in that state
  [[ "$(jq -r "[.releases[] | select(.tag_name == \"v1.0.1\")] | length == 1 and .[0].draft == $1" "$MOCK_DIR/state.json" 2>/dev/null)" == true ]]
}

make_artifact "$tmp/ci-unsigned.apk"
check tag-lightweight fail 'lightweight tag' -- publish lightweight
check tag-not-on-main fail 'not on main' -- publish not_on_main
check release-draft-exists fail 'already exists' -- publish existing_draft
check run-missing fail 'no successful' -- publish no_run
check run-ambiguous fail 'choose one with --run-id' -- publish two_runs
check run-wrong-workflow fail "release-preflight.yml', expected" -- publish wrong_workflow
check artifact-preflight fail '0 artifacts named release-unsigned-1.0.1' -- publish preflight_artifact
check artifact-expired fail 'expired' -- publish expired
check artifact-digest fail "recorded digest" -- publish bad_digest
make_artifact "$tmp/ci-unsigned.apk" "" evil.txt
check artifact-extra-file fail 'artifact contains' -- publish ok
make_artifact "$tmp/ci-unsigned.apk" 'm["commit"] = "a" * 40'
check manifest-commit fail 'manifest commit is' -- publish ok
make_artifact "$tmp/ci-unsigned.apk" 'm["unsigned_apk_sha256"] = "0" * 64'
check manifest-apk-hash fail 'unsigned_apk_sha256' -- publish ok
make_artifact "$tmp/ci-unsigned.apk" 'm["extra"] = 1'
check manifest-schema fail 'unexpected' -- publish ok
make_artifact "$tmp/local-signed.apk"
check ci-apk-is-signed fail 'unexpectedly has an APK Signing Block' -- publish ok

make_artifact "$tmp/ci-unsigned.apk"
mv "$repo/keystore.properties" "$tmp/kp"
check key-missing fail 'no signing key configured' -- publish ok
mv "$tmp/kp" "$repo/keystore.properties"
export FIXTURE_LOCAL_DIFFERS=1
check local-differs-from-ci fail 'local build does not match the CI artifact' -- publish ok
unset FIXTURE_LOCAL_DIFFERS
assert local-differs-no-signed-output no_signed_output
make_artifact "$tmp/plain-unsigned.apk"
check padding-rejected fail 'extra bytes between the ZIP entries' -- publish ok
assert padding-no-signed-output no_signed_output

make_artifact "$tmp/ci-unsigned.apk"
check dry-run-ok ok 'apksigcopier compare: signature can be copied' -- publish ok
assert dry-run-keeps-human-notes grep -q 'Thanks to \[@tester\]' "$repo/build/release/v1.0.1/release-notes.md"
# Each case's exit status is the published state it must leave behind.
confirm_mismatch() { publish_confirm ok nope; [[ -e "$MOCK_DIR/state.json" ]]; }  # nothing created
upload_corrupt() { publish_confirm upload_corrupt v1.0.1; ! released true; }      # draft kept unpublished
publish_ok() { publish_confirm ok v1.0.1; released false; }                        # published
check confirm-mismatch fail 'confirmation did not match' -- confirm_mismatch
check upload-corrupt fail 'left unpublished' -- upload_corrupt
check publish-ok ok 'ok: published' -- publish_ok
leaked="$(find "$TMPDIR" -name keystore.properties 2>/dev/null)"
assert no-temporary-keystore-left test -z "$leaked"

# --- optional: real Gradle build of the app -------------------------------------------------

if $full; then
  echo "== --full: real Gradle builds of HEAD (AGP signing layout)"
  app="$tmp/app"
  git clone -q --shared --no-tags "$SRC_ROOT" "$app"
  rm -rf "$app/scripts/release"; mkdir -p "$app/scripts"; cp -r "$SRC_ROOT/scripts/release" "$app/scripts/"
  sed -i "s/^SIGNING_CERT_SHA256=.*/SIGNING_CERT_SHA256=\"$test_cert\"/" "$app/scripts/release/release.conf"
  read -r fcode fname < <(python3 "$app/scripts/release/release_tool.py" gradle-version <"$app/$GRADLE_FILE")
  mkdir -p "$app/$NOTES_DIR"
  [[ -f "$app/$NOTES_DIR/v$fname.md" ]] || \
    printf '# v%s - Test release\n\nTest notes.\n' "$fname" >"$app/$NOTES_DIR/v$fname.md"
  ga() { git -C "$app" -c user.name=test -c user.email=test@example.invalid "$@"; }
  ga add -A && ga commit -qm "release-tooling test" && ga tag -a "v$fname" -m "v$fname"
  printf 'storeFile=%s\nstorePassword=test-pass\nkeyAlias=test\nkeyPassword=test-pass\n' "$tmp/test.p12" >"$app/keystore.properties"
  ci="$tmp/ci-full"
  git clone -q --shared --no-tags "$app" "$ci" && git -C "$ci" checkout -q --detach "$(ga rev-parse HEAD)"
  (cd "$ci" && ./gradlew --no-daemon --quiet assembleRelease) >/dev/null 2>&1
  MOCK_COMMIT="$(ga rev-parse HEAD)"; MOCK_TAGOBJ="$(ga rev-parse "v$fname")"
  export MOCK_TAG="v$fname" MOCK_PREV_TAG=v0.0.1 MOCK_VERSION_CODE="$fcode" MOCK_COMMIT MOCK_TAGOBJ
  make_artifact "$ci/$UNSIGNED_APK_GRADLE_PATH"
  rm -rf "$MOCK_DIR/state.json"
  check full-agp-dry-run ok 'no padding' -- bash -c \
    "cd '$app' && PATH='$HERE/mock:$PATH' scripts/release/publish-release.sh 'v$fname' --dry-run"
fi

echo
echo "RESULT: $pass passed, $fail failed"
((fail == 0))
