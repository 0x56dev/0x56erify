#!/usr/bin/env python3
"""Helpers for the 0x56erify release scripts.

Subcommands (each exits non-zero with an "ERROR:" message on failure):

  gradle-version        read app/build.gradle.kts on stdin, print "<code> <name>"
  sigblock APK          print the APK Signing Block pair IDs (hex), or "none"
  v1-files APK          print JAR-signature files under META-INF/, if any
  compare SIGNED UNSIGNED
                        check SIGNED is exactly UNSIGNED plus an APK Signing Block
  junit DIR             summarise JUnit XML results as JSON
  notes-check VERSION FILE
                        validate a human-written release-notes file, print its title
  notes-render ...      write the final release title/body (human notes + build facts)
  manifest-write ...    write release-manifest.json
  manifest-check ...    strictly validate release-manifest.json against expected values

Only the standard library is used so this runs unchanged locally and in CI.
"""

import argparse
import glob
import hashlib
import json
import os
import re
import struct
import sys
import xml.etree.ElementTree as ET
import zipfile

APK_SIG_BLOCK_MAGIC = b"APK Sig Block 42"
EOCD_SIG = b"PK\x05\x06"

SIG_BLOCK_IDS = {
    0x7109871A: "APK Signature Scheme v2",
    0xF05368C0: "APK Signature Scheme v3",
    0x1B93AD61: "APK Signature Scheme v3.1",
    0x42726577: "verity padding",
    0x504B4453: "dependency-info (Play dependency metadata)",
    0x6DFF800D: "source stamp",
    0x2146444E: "Play frosting",
}
# The only blocks a release APK may carry: the v2 signature and the padding
# apksigner/AGP insert for alignment.
ALLOWED_SIGNED_IDS = {0x7109871A, 0x42726577}

MANIFEST_SCHEMA = 1
MANIFEST_KEYS = {
    "schema", "mode", "repository", "workflow_ref", "run_id", "run_attempt",
    "ref", "tag", "tag_object", "commit", "package", "version_name",
    "version_code", "unsigned_apk", "unsigned_apk_sha256", "unit_tests",
    "lint_task", "build_tools",
}
UNIT_TEST_KEYS = {"total", "failures", "errors", "skipped"}

GRADLE_CODE_RE = re.compile(r"versionCode\s*=\s*(\d+)")   # same as F-Droid UpdateCheckData
GRADLE_NAME_RE = re.compile(r'versionName\s*=\s*"([^"]+)"')
VERSION_RE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SHA1_RE = re.compile(r"^[0-9a-f]{40}$")


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# --- ZIP / APK Signing Block -------------------------------------------------

class ApkLayout:
    """Byte layout of an APK: entries | [signing block] | central dir | EOCD."""

    def __init__(self, path):
        with open(path, "rb") as f:
            self.data = f.read()
        d = self.data
        eocd = d.rfind(EOCD_SIG, max(0, len(d) - 65557))
        if eocd < 0 or len(d) - eocd < 22:
            die(f"{path}: not a ZIP/APK (no end-of-central-directory record)")
        (_, disk, cd_disk, n_disk, n_total, cd_size, cd_off, comment_len) = struct.unpack(
            "<IHHHHIIH", d[eocd:eocd + 22])
        if eocd + 22 + comment_len != len(d):
            die(f"{path}: unexpected data after the ZIP end-of-central-directory record")
        if disk or cd_disk or n_disk != n_total:
            die(f"{path}: multi-disk ZIP archives are not supported")
        if cd_off == 0xFFFFFFFF or cd_size == 0xFFFFFFFF:
            die(f"{path}: ZIP64 archives are not supported")
        if cd_off + cd_size != eocd:
            die(f"{path}: central directory does not end at the EOCD record")
        self.eocd = eocd
        self.cd_off = cd_off
        self.cd_size = cd_size
        self.block_start = None
        self.pairs = []
        if cd_off >= 32 and d[cd_off - 16:cd_off] == APK_SIG_BLOCK_MAGIC:
            (size_footer,) = struct.unpack("<Q", d[cd_off - 24:cd_off - 16])
            start = cd_off - (size_footer + 8)
            if start < 0:
                die(f"{path}: corrupt APK Signing Block size")
            (size_header,) = struct.unpack("<Q", d[start:start + 8])
            if size_header != size_footer:
                die(f"{path}: APK Signing Block header/footer sizes disagree")
            self.block_start = start
            pos, end = start + 8, cd_off - 24
            while pos < end:
                if end - pos < 12:
                    die(f"{path}: truncated APK Signing Block pair")
                (plen,) = struct.unpack("<Q", d[pos:pos + 8])
                if plen < 4 or pos + 8 + plen > end:
                    die(f"{path}: corrupt APK Signing Block pair length")
                (pid,) = struct.unpack("<I", d[pos + 8:pos + 12])
                self.pairs.append(pid)
                pos += 8 + plen

    @property
    def entries_end(self):
        return self.block_start if self.block_start is not None else self.cd_off


def cmd_sigblock(args):
    layout = ApkLayout(args.apk)
    if layout.block_start is None:
        print("none")
        return
    for pid in layout.pairs:
        print(f"0x{pid:08x} {SIG_BLOCK_IDS.get(pid, 'unknown')}")


def cmd_v1_files(args):
    pat = re.compile(r"^META-INF/[^/]+\.(SF|RSA|DSA|EC)$", re.IGNORECASE)
    with zipfile.ZipFile(args.apk) as z:
        for name in z.namelist():
            if pat.match(name):
                print(name)


def cmd_compare(args):
    """SIGNED must equal UNSIGNED with one APK Signing Block inserted directly
    before the central directory (and the EOCD's central-directory offset
    adjusted) - nothing else. AGP's in-build signer produces exactly this
    layout (as for every release so far), it is what F-Droid relies on when it
    copies our signature onto its own unsigned build, and it proves the signed
    APK has the same contents as the unsigned one. Padding before the block, as
    standalone apksigner adds, is rejected."""
    s = ApkLayout(args.signed)
    u = ApkLayout(args.unsigned)
    if u.block_start is not None:
        die(f"{args.unsigned}: expected an unsigned APK but it has an APK Signing Block")
    if s.block_start is None:
        die(f"{args.signed}: expected a signed APK but it has no APK Signing Block")
    if s.data[:u.cd_off] != u.data[:u.cd_off]:
        die("signed APK's ZIP entries are not byte-identical to the unsigned APK's")
    if s.block_start != u.cd_off:
        die(f"signed APK has {s.block_start - u.cd_off} extra bytes between the ZIP entries "
            "and the APK Signing Block (standalone-apksigner-style padding or rewritten "
            "entries); expected the AGP signing layout")
    block = s.data[s.block_start:s.cd_off]
    new_eocd = bytearray(u.data[u.eocd:])
    struct.pack_into("<I", new_eocd, 16, u.cd_off + len(block))
    expected = u.data[:u.cd_off] + block + u.data[u.cd_off:u.eocd] + bytes(new_eocd)
    if expected != s.data:
        die("signed APK is not exactly the unsigned APK plus an APK Signing Block "
            "(central directory or EOCD differ)")
    print("signed APK == unsigned APK + APK Signing Block (no padding)")


# --- Gradle version values -------------------------------------------------

def cmd_gradle_version(args):
    text = sys.stdin.read()
    codes = GRADLE_CODE_RE.findall(text)
    names = GRADLE_NAME_RE.findall(text)
    if len(codes) != 1:
        die(f"expected exactly one 'versionCode = N' in the Gradle file, found {len(codes)} "
            "(F-Droid's UpdateCheckData uses the first match)")
    if len(names) != 1:
        die(f"expected exactly one 'versionName = \"...\"' in the Gradle file, found {len(names)}")
    code = int(codes[0])
    if code < 1 or code > 2100000000:
        die(f"versionCode {code} is out of range")
    print(f"{code} {names[0]}")


# --- JUnit results -----------------------------------------------------------

def cmd_junit(args):
    files = sorted(glob.glob(os.path.join(args.dir, "TEST-*.xml")))
    if not files:
        die(f"no JUnit result files in {args.dir}")
    totals = {k: 0 for k in UNIT_TEST_KEYS}
    for path in files:
        root = ET.parse(path).getroot()
        suites = [root] if root.tag == "testsuite" else root.findall("testsuite")
        for suite in suites:
            totals["total"] += int(suite.get("tests", 0))
            totals["failures"] += int(suite.get("failures", 0))
            totals["errors"] += int(suite.get("errors", 0))
            totals["skipped"] += int(suite.get("skipped", 0))
    if totals["total"] == 0:
        die("JUnit results report zero tests")
    if totals["failures"] or totals["errors"]:
        die(f"unit tests failed: {totals}")
    print(json.dumps(totals, sort_keys=True))


# --- Release notes -----------------------------------------------------------

RESERVED_HEADING_RE = re.compile(r"^#{1,6}\s*this build\s*$", re.IGNORECASE | re.MULTILINE)
PLACEHOLDER_RE = re.compile(r"\b(TODO|TBD|FIXME|XXX)\b|<!--|\]\(\s*\)")


def read_notes(version, path, name=None):
    shown = name or path
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        die(f"release notes {shown} not found (see .github/release-notes/README.md)")
    except UnicodeDecodeError:
        die(f"release notes {shown} are not valid UTF-8")
    text = text.replace("\r\n", "\n")
    if len(text.encode()) > 100_000:
        die(f"release notes {shown} are larger than 100 kB")
    lines = text.split("\n")
    m = re.match(r"^# (v" + re.escape(version) + r" - \S.*?)\s*$", lines[0])
    if not m:
        die(f"{shown}: first line must be '# v{version} - <short title>' (got {lines[0]!r})")
    title = m.group(1)
    if len(lines) < 2 or lines[1].strip():
        die(f"{shown}: the title line must be followed by a blank line")
    body = "\n".join(lines[2:]).strip()
    if not body:
        die(f"{shown}: release notes body is empty")
    if RESERVED_HEADING_RE.search(body):
        die(f"{shown}: the '## This build' section is generated by the release script; "
            "remove it from the notes file")
    ph = PLACEHOLDER_RE.search(body)
    if ph:
        die(f"{shown}: contains placeholder/template text {ph.group(0)!r}")
    return title, body


def cmd_notes_check(args):
    if not VERSION_RE.match(args.version):
        die(f"invalid version {args.version!r}")
    title, _ = read_notes(args.version, args.file, args.name)
    print(title)


def cmd_notes_render(args):
    title, body = read_notes(args.version, args.notes)
    tests = json.loads(args.unit_tests)
    passed = tests["total"] - tests["skipped"]
    test_line = f"{passed}/{tests['total']} unit tests passed"
    if tests["skipped"]:
        test_line += f" ({tests['skipped']} skipped)"
    footer = "\n".join([
        "## This build",
        f"- Built from tag `{args.tag}` (commit `{args.commit}`) by "
        f"[GitHub Actions run {args.run_id}]({args.run_url})",
        f"- {test_line} (`testReleaseUnitTest`); `lintVitalRelease` passed",
        "- Unsigned APK built in CI and rebuilt locally with identical contents; "
        "signed by the local Gradle release build with the same key as previous releases",
        f"- Signing certificate SHA-256: `{args.cert}`",
        "- APK Signature Scheme v2 only; no dependency-info signing block",
        "- No `INTERNET` permission",
        "",
        f"**versionCode:** {args.version_code} · **versionName:** {args.version}",
        "",
        f"**APK SHA-256:** `{args.apk_sha256}`",
        "",
    ])
    with open(args.title_out, "w", encoding="utf-8") as f:
        f.write(title + "\n")
    with open(args.body_out, "w", encoding="utf-8") as f:
        f.write(body + "\n\n" + footer)


# --- Manifest ----------------------------------------------------------------

def cmd_manifest_write(args):
    tests = json.loads(args.unit_tests)
    manifest = {
        "schema": MANIFEST_SCHEMA,
        "mode": args.mode,
        "repository": args.repository,
        "workflow_ref": args.workflow_ref,
        "run_id": int(args.run_id),
        "run_attempt": int(args.run_attempt),
        "ref": args.ref,
        "tag": args.tag or None,
        "tag_object": args.tag_object or None,
        "commit": args.commit,
        "package": args.package,
        "version_name": args.version_name,
        "version_code": int(args.version_code),
        "unsigned_apk": os.path.basename(args.apk),
        "unsigned_apk_sha256": sha256_file(args.apk),
        "unit_tests": tests,
        "lint_task": "lintVitalRelease",
        "build_tools": args.build_tools,
    }
    validate_manifest_shape(manifest)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")


def validate_manifest_shape(m):
    if not isinstance(m, dict):
        die("manifest is not a JSON object")
    keys = set(m)
    if keys != MANIFEST_KEYS:
        die(f"manifest keys differ from schema {MANIFEST_SCHEMA}: "
            f"missing {sorted(MANIFEST_KEYS - keys)}, unexpected {sorted(keys - MANIFEST_KEYS)}")
    if m["schema"] != MANIFEST_SCHEMA:
        die(f"unsupported manifest schema {m['schema']!r}")
    if m["mode"] not in ("release", "preflight"):
        die(f"invalid manifest mode {m['mode']!r}")
    for k in ("run_id", "run_attempt", "version_code"):
        if type(m[k]) is not int or m[k] < 1:
            die(f"manifest {k} must be a positive integer")
    if not SHA1_RE.match(str(m["commit"])):
        die("manifest commit is not a full lowercase SHA-1")
    if not SHA256_RE.match(str(m["unsigned_apk_sha256"])):
        die("manifest unsigned_apk_sha256 is not a lowercase SHA-256")
    if not VERSION_RE.match(str(m["version_name"])):
        die("manifest version_name is not MAJOR.MINOR.PATCH")
    t = m["unit_tests"]
    if not isinstance(t, dict) or set(t) != UNIT_TEST_KEYS or any(
            type(v) is not int or v < 0 for v in t.values()):
        die("manifest unit_tests is malformed")
    if t["total"] < 1 or t["failures"] or t["errors"]:
        die(f"manifest records failing or missing unit tests: {t}")
    if m["mode"] == "release":
        if m["tag"] != "v" + m["version_name"] or m["ref"] != "refs/tags/" + m["tag"]:
            die("manifest tag/ref do not match its version")
        if not SHA1_RE.match(str(m["tag_object"])):
            die("manifest tag_object is not a full SHA-1")
    elif m["tag"] is not None or m["tag_object"] is not None:
        die("preflight manifest must not name a tag")


def cmd_manifest_check(args):
    try:
        with open(args.manifest, encoding="utf-8") as f:
            m = json.load(f)
    except (OSError, ValueError) as e:
        die(f"cannot read manifest: {e}")
    validate_manifest_shape(m)
    expected = {}
    for item in args.expect:
        k, sep, v = item.partition("=")
        if not sep or k not in MANIFEST_KEYS:
            die(f"bad --expect {item!r}")
        expected[k] = v
    for k, v in expected.items():
        actual = m[k]
        if str(actual) != v:
            die(f"manifest {k} is {actual!r}, expected {v!r}")
    print(json.dumps(m["unit_tests"], sort_keys=True))


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("gradle-version").set_defaults(fn=cmd_gradle_version)
    s = sub.add_parser("sigblock"); s.add_argument("apk"); s.set_defaults(fn=cmd_sigblock)
    s = sub.add_parser("v1-files"); s.add_argument("apk"); s.set_defaults(fn=cmd_v1_files)
    s = sub.add_parser("compare"); s.add_argument("signed"); s.add_argument("unsigned")
    s.set_defaults(fn=cmd_compare)
    s = sub.add_parser("junit"); s.add_argument("dir"); s.set_defaults(fn=cmd_junit)
    s = sub.add_parser("notes-check"); s.add_argument("version"); s.add_argument("file")
    s.add_argument("--name", help="path to show in error messages")
    s.set_defaults(fn=cmd_notes_check)

    s = sub.add_parser("notes-render")
    for a in ("version", "version-code", "notes", "tag", "commit", "run-id", "run-url",
              "unit-tests", "cert", "apk-sha256", "title-out", "body-out"):
        s.add_argument("--" + a, required=True)
    s.set_defaults(fn=cmd_notes_render)

    s = sub.add_parser("manifest-write")
    for a in ("mode", "repository", "workflow-ref", "run-id", "run-attempt", "ref", "commit",
              "package", "version-name", "version-code", "apk", "unit-tests", "build-tools", "out"):
        s.add_argument("--" + a, required=True)
    s.add_argument("--tag", default="")
    s.add_argument("--tag-object", default="")
    s.set_defaults(fn=cmd_manifest_write)

    s = sub.add_parser("manifest-check"); s.add_argument("manifest")
    s.add_argument("--expect", action="append", default=[], metavar="KEY=VALUE")
    s.set_defaults(fn=cmd_manifest_check)

    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
