#!/usr/bin/env bash
# Check a release APK's identity, permissions and signing state.
#
#   check-apk.sh --unsigned APK --version 0.1.4 --code 5
#   check-apk.sh --signed   APK --version 0.1.4 --code 5
#
# Unsigned: no APK Signing Block and no JAR signature at all.
# Signed:   exactly one signer with the pinned certificate, APK Signature
#           Scheme v2 only, and no signing-block entries other than the v2
#           signature and alignment padding (so no dependency-info block).
# Both:     package, versionCode/versionName, minSdk >= 24 (v2-only signing),
#           not debuggable/testOnly, only allow-listed permissions, zipalign.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { die "usage: ${0##*/} --unsigned|--signed APK --version X.Y.Z --code N"; }

kind="" apk="" version="" code=""
while (($#)); do
  case "$1" in
    --unsigned|--signed) [[ -z "$kind" && $# -ge 2 ]] || usage; kind="${1#--}"; apk="$2"; shift 2 ;;
    --version) [[ $# -ge 2 ]] || usage; version="$2"; shift 2 ;;
    --code)    [[ $# -ge 2 ]] || usage; code="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$kind" && -n "$apk" && -n "$version" && -n "$code" ]] || usage
validate_version "$version"
[[ "$code" =~ ^[1-9][0-9]*$ ]] || die "invalid versionCode '$code'"
[[ -f "$apk" ]] || die "APK not found: $apk"

load_build_tools
step "Checking $kind APK $(basename "$apk")"

# Alignment (4-byte, page-aligned native libraries).
"$ZIPALIGN" -c -p 4 "$apk" >/dev/null 2>&1 \
  || die "$apk is not zip-aligned (zipalign -c -p 4 failed)"
ok "zip-aligned"

# Package identity.
badging="$("$AAPT2" dump badging "$apk" 2>&1)" || die "aapt2 could not read $apk:"$'\n'"$badging"
pkg_line="$(grep -m1 '^package: ' <<<"$badging" || true)"
[[ "$pkg_line" =~ ^package:\ name=\'([^\']*)\'\ versionCode=\'([^\']*)\'\ versionName=\'([^\']*)\' ]] \
  || die "could not parse aapt2 package line: $pkg_line"
got_pkg="${BASH_REMATCH[1]}" got_code="${BASH_REMATCH[2]}" got_name="${BASH_REMATCH[3]}"
[[ "$got_pkg" == "$PACKAGE_NAME" ]] || die "APK package is '$got_pkg', expected '$PACKAGE_NAME'"
[[ "$got_code" == "$code" ]] || die "APK versionCode is '$got_code', expected '$code'"
[[ "$got_name" == "$version" ]] || die "APK versionName is '$got_name', expected '$version'"
ok "package $got_pkg, versionCode $got_code, versionName $got_name"

min_sdk="$(sed -n "s/^minSdkVersion:'\([0-9]*\)'.*/\1/p" <<<"$badging")"
[[ "$min_sdk" =~ ^[0-9]+$ ]] || die "could not read minSdkVersion"
((min_sdk >= 24)) || die "minSdkVersion $min_sdk < 24: v2-only signing would not install; revisit signing schemes"
ok "minSdkVersion $min_sdk"

grep -q '^application-debuggable' <<<"$badging" && die "APK is debuggable"
grep -q "^testOnly=" <<<"$badging" && die "APK is marked testOnly"
ok "not debuggable, not testOnly"

# Permissions: everything requested or declared must be allow-listed.
perms_out="$("$AAPT2" dump permissions "$apk" 2>&1)" || die "aapt2 could not dump permissions:"$'\n'"$perms_out"
mapfile -t perms < <(
  sed -n -e "s/^uses-permission[^:]*: name='\([^']*\)'.*/\1/p" \
         -e "s/^permission: \(.*\)$/\1/p" <<<"$perms_out" | sort -u
)
for p in "${perms[@]}"; do
  for f in "${FORBIDDEN_PERMISSIONS[@]}"; do
    [[ "$p" == "$f" ]] && die "APK requests forbidden permission $p"
  done
  allowed=false
  for a in "${ALLOWED_PERMISSIONS[@]}"; do [[ "$p" == "$a" ]] && allowed=true; done
  $allowed || die "APK requests or declares unexpected permission '$p' (not in ALLOWED_PERMISSIONS in release.conf)"
done
ok "permissions: ${perms[*]:-none} (no INTERNET)"

# Signing state.
v1_files="$(python3 "$RELEASE_TOOL" v1-files "$apk")"
[[ -z "$v1_files" ]] || die "APK contains JAR (v1) signature files: $v1_files"
blocks="$(python3 "$RELEASE_TOOL" sigblock "$apk")"

if [[ "$kind" == "unsigned" ]]; then
  [[ "$blocks" == "none" ]] || die "unsigned APK unexpectedly has an APK Signing Block:"$'\n'"$blocks"
  ok "no APK Signing Block, no JAR signature"
  exit 0
fi

[[ "$blocks" != "none" ]] || die "APK has no APK Signing Block: it is not signed"
grep -qi '^0x504b4453' <<<"$blocks" && die "APK contains a dependency-info signing block (dependenciesInfo must stay disabled)"
while read -r id desc; do
  case "$id" in
    0x7109871a|0x42726577) ;;
    *) die "APK Signing Block contains unexpected entry $id ($desc)" ;;
  esac
done <<<"$blocks"
grep -qi '^0x7109871a' <<<"$blocks" || die "APK Signing Block has no v2 signature"
ok "signing block entries: $(awk '{print $1}' <<<"$blocks" | paste -sd, -)"

verify_out="$("$APKSIGNER" verify --verbose --print-certs -- "$apk" 2>&1)" \
  || die "apksigner verify failed:"$'\n'"$verify_out"
grep -q '^WARNING' <<<"$verify_out" && die "apksigner reported warnings:"$'\n'"$(grep '^WARNING' <<<"$verify_out")"
expect_line() {
  grep -Fxq -- "$1" <<<"$verify_out" || die "apksigner: expected '$1'"$'\n'"$verify_out"
}
expect_line "Verified using v1 scheme (JAR signing): false"
expect_line "Verified using v2 scheme (APK Signature Scheme v2): true"
expect_line "Verified using v3 scheme (APK Signature Scheme v3): false"
expect_line "Verified using v3.1 scheme (APK Signature Scheme v3.1): false"
expect_line "Verified using v4 scheme (APK Signature Scheme v4): false"
expect_line "Number of signers: 1"
cert="$(apk_cert_sha256 "$apk")"
[[ "$cert" == "$SIGNING_CERT_SHA256" ]] \
  || die "APK signing certificate is $cert, expected the release certificate $SIGNING_CERT_SHA256"
ok "signed by release certificate $cert (v2 only, 1 signer)"
