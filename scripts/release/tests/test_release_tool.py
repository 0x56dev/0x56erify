#!/usr/bin/env python3
"""Unit tests for scripts/release/release_tool.py (standard library only).

Covers the invariants the release scripts rely on: exact signed/unsigned APK
layout (no padding), signing-block inspection, strict manifest validation,
release-notes rules, Gradle version parsing and JUnit summaries. APKs here are
tiny synthetic ZIPs; nothing is signed.
"""

import io
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "release_tool.py")
V2_ID, PADDING_ID, DEPENDENCY_INFO_ID = 0x7109871A, 0x42726577, 0x504B4453


def run(*args, stdin=None):
    return subprocess.run([sys.executable, TOOL, *args], input=stdin,
                          capture_output=True, text=True)


def make_zip(entries=(("a.txt", b"hello"), ("b.txt", b"world"))):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as z:
        for name, data in entries:
            z.writestr(zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0)), data)
    return buf.getvalue()


def zip_offsets(data):
    eocd = data.rfind(b"PK\x05\x06")
    cd_off = struct.unpack("<I", data[eocd + 16:eocd + 20])[0]
    return cd_off, eocd


def signing_block(pair_ids):
    pairs = b"".join(struct.pack("<QI", 4 + 8, pid) + b"\x00" * 8 for pid in pair_ids)
    size = len(pairs) + 8 + 16
    return struct.pack("<Q", size) + pairs + struct.pack("<Q", size) + b"APK Sig Block 42"


def insert_block(unsigned, block, padding=b""):
    cd_off, eocd = zip_offsets(unsigned)
    tail = bytearray(unsigned[eocd:])
    struct.pack_into("<I", tail, 16, cd_off + len(padding) + len(block))
    return unsigned[:cd_off] + padding + block + unsigned[cd_off:eocd] + bytes(tail)


class TempFiles(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)

    def write(self, name, data):
        path = os.path.join(self._dir.name, name)
        with open(path, "wb" if isinstance(data, bytes) else "w") as f:
            f.write(data)
        return path


class CompareTest(TempFiles):
    def setUp(self):
        super().setUp()
        self.unsigned_bytes = make_zip()
        self.unsigned = self.write("u.apk", self.unsigned_bytes)
        self.block = signing_block([V2_ID, PADDING_ID])

    def compare(self, signed_bytes, unsigned=None):
        return run("compare", self.write("s.apk", signed_bytes), unsigned or self.unsigned)

    def test_exact_block_insertion_is_accepted(self):
        r = self.compare(insert_block(self.unsigned_bytes, self.block))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("no padding", r.stdout)

    def test_padding_before_block_is_rejected(self):
        # Standalone apksigner zero-pads the entries so the block is 4096-aligned.
        cd_off, _ = zip_offsets(self.unsigned_bytes)
        pad = b"\x00" * (4096 - cd_off % 4096)
        r = self.compare(insert_block(self.unsigned_bytes, self.block, pad))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("extra bytes", r.stderr)

    def test_changed_entry_is_rejected(self):
        other = make_zip((("a.txt", b"HELLO"), ("b.txt", b"world")))
        r = self.compare(insert_block(other, self.block))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not byte-identical", r.stderr)

    def test_changed_central_directory_is_rejected(self):
        signed = bytearray(insert_block(self.unsigned_bytes, self.block))
        cd = bytes(signed).rfind(b"PK\x01\x02")
        signed[cd + 12] ^= 1  # last-modified date in the last central directory record
        r = self.compare(bytes(signed))
        self.assertNotEqual(r.returncode, 0)

    def test_unsigned_input_with_block_is_rejected(self):
        signed = insert_block(self.unsigned_bytes, self.block)
        r = self.compare(signed, unsigned=self.write("u2.apk", signed))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("expected an unsigned APK", r.stderr)

    def test_signed_input_without_block_is_rejected(self):
        r = self.compare(self.unsigned_bytes)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no APK Signing Block", r.stderr)


class SigBlockTest(TempFiles):
    def test_lists_pair_ids(self):
        apk = self.write("s.apk", insert_block(make_zip(), signing_block([V2_ID, DEPENDENCY_INFO_ID])))
        r = run("sigblock", apk)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("0x7109871a", r.stdout)
        self.assertIn("0x504b4453 dependency-info", r.stdout)

    def test_unsigned_reports_none(self):
        r = run("sigblock", self.write("u.apk", make_zip()))
        self.assertEqual(r.stdout.strip(), "none")

    def test_trailing_data_is_rejected(self):
        r = run("sigblock", self.write("x.apk", make_zip() + b"junk"))
        self.assertNotEqual(r.returncode, 0)

    def test_v1_signature_files_are_listed(self):
        apk = self.write("v1.apk", make_zip((("META-INF/CERT.RSA", b"x"), ("a", b"y"))))
        self.assertIn("META-INF/CERT.RSA", run("v1-files", apk).stdout)


class GradleVersionTest(unittest.TestCase):
    def test_single_values(self):
        r = run("gradle-version", stdin='versionCode = 5\n        versionName = "0.1.4"\n')
        self.assertEqual(r.stdout.strip(), "5 0.1.4")

    def test_duplicate_version_code_is_rejected(self):
        r = run("gradle-version", stdin='versionCode = 5\n// versionCode = 9\nversionName = "0.1.4"\n')
        self.assertNotEqual(r.returncode, 0)

    def test_missing_version_name_is_rejected(self):
        self.assertNotEqual(run("gradle-version", stdin="versionCode = 5\n").returncode, 0)


NOTES_OK = """# v1.2.3 - Fix things

Summary.

## Fixed
- A bug.

Thanks to volunteer tester [@someone](https://github.com/someone) for reporting this.
"""


class NotesTest(TempFiles):
    def check(self, text, version="1.2.3"):
        return run("notes-check", "--name", "notes.md", version, self.write("n.md", text))

    def test_valid_notes(self):
        r = self.check(NOTES_OK)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "v1.2.3 - Fix things")

    def test_rejections(self):
        cases = {
            "wrong version": NOTES_OK.replace("v1.2.3", "v1.2.4"),
            "no title separator": NOTES_OK.replace("v1.2.3 - Fix", "v1.2.3 Fix"),
            "no blank line": NOTES_OK.replace("things\n\n", "things\n"),
            "empty body": "# v1.2.3 - Fix things\n\n  \n",
            "TODO": NOTES_OK + "- TODO\n",
            "TBD": NOTES_OK + "TBD\n",
            "HTML comment": NOTES_OK + "<!-- x -->\n",
            "empty link": NOTES_OK + "[x]()\n",
            "reserved heading": NOTES_OK + "\n## This build\n- x\n",
        }
        for label, text in cases.items():
            with self.subTest(label):
                r = self.check(text)
                self.assertNotEqual(r.returncode, 0, label)
                self.assertIn("notes.md", r.stderr)  # errors name the real file

    def test_render_keeps_human_text_and_appends_build_facts(self):
        d = self._dir.name
        r = run("notes-render", "--version", "1.2.3", "--version-code", "7",
                "--notes", self.write("n.md", NOTES_OK), "--tag", "v1.2.3", "--commit", "c" * 40,
                "--run-id", "42", "--run-url", "https://example.invalid/run/42",
                "--unit-tests", '{"total": 3, "failures": 0, "errors": 0, "skipped": 0}',
                "--cert", "e" * 64, "--apk-sha256", "f" * 64,
                "--title-out", os.path.join(d, "t"), "--body-out", os.path.join(d, "b"))
        self.assertEqual(r.returncode, 0, r.stderr)
        body = open(os.path.join(d, "b")).read()
        human = NOTES_OK.split("\n", 2)[2].strip()
        self.assertTrue(body.startswith(human), "human-written notes must be kept verbatim")
        self.assertIn("## This build", body)
        self.assertIn("f" * 64, body)
        self.assertEqual(open(os.path.join(d, "t")).read().strip(), "v1.2.3 - Fix things")


class ManifestTest(TempFiles):
    def setUp(self):
        super().setUp()
        self.apk = self.write("app-unsigned.apk", make_zip())
        self.path = os.path.join(self._dir.name, "release-manifest.json")
        r = run("manifest-write", "--mode", "release", "--repository", "o/r",
                "--workflow-ref", "o/r/.github/workflows/release.yml@refs/tags/v1.2.3",
                "--run-id", "42", "--run-attempt", "1", "--ref", "refs/tags/v1.2.3",
                "--tag", "v1.2.3", "--tag-object", "a" * 40, "--commit", "b" * 40,
                "--package", "p.q", "--version-name", "1.2.3", "--version-code", "7",
                "--apk", self.apk, "--unit-tests",
                '{"total": 3, "failures": 0, "errors": 0, "skipped": 0}',
                "--build-tools", "35.0.0", "--out", self.path)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.manifest = json.load(open(self.path))

    def check(self, manifest, *expect):
        path = self.write("m.json", json.dumps(manifest))
        args = []
        for e in expect:
            args += ["--expect", e]
        return run("manifest-check", path, *args)

    def test_valid_manifest_matches_expectations(self):
        r = self.check(self.manifest, "run_id=42", "commit=" + "b" * 40, "version_code=7",
                       "unsigned_apk_sha256=" + self.manifest["unsigned_apk_sha256"])
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_mismatched_expectation_is_rejected(self):
        self.assertNotEqual(self.check(self.manifest, "run_id=43").returncode, 0)

    def test_tampering_is_rejected(self):
        tamper = {
            "extra key": lambda m: m.update(extra=1),
            "missing key": lambda m: m.pop("lint_task"),
            "string versionCode": lambda m: m.update(version_code="7"),
            "failing tests": lambda m: m["unit_tests"].update(failures=1),
            "zero tests": lambda m: m["unit_tests"].update(total=0),
            "tag/version mismatch": lambda m: m.update(tag="v9.9.9"),
            "preflight naming a tag": lambda m: m.update(mode="preflight"),
            "short commit": lambda m: m.update(commit="abc"),
            "unknown schema": lambda m: m.update(schema=2),
        }
        for label, fn in tamper.items():
            with self.subTest(label):
                m = json.loads(json.dumps(self.manifest))
                fn(m)
                self.assertNotEqual(self.check(m).returncode, 0, label)


class JUnitTest(TempFiles):
    def results(self, **attrs):
        d = tempfile.mkdtemp(dir=self._dir.name)
        a = " ".join(f'{k}="{v}"' for k, v in attrs.items())
        with open(os.path.join(d, "TEST-x.xml"), "w") as f:
            f.write(f'<testsuite name="x" {a}></testsuite>')
        return run("junit", d)

    def test_passing(self):
        r = self.results(tests=3, failures=0, errors=0, skipped=1)
        self.assertEqual(json.loads(r.stdout), {"total": 3, "failures": 0, "errors": 0, "skipped": 1})

    def test_failures_and_empty_are_rejected(self):
        self.assertNotEqual(self.results(tests=3, failures=1, errors=0, skipped=0).returncode, 0)
        self.assertNotEqual(self.results(tests=0, failures=0, errors=0, skipped=0).returncode, 0)


if __name__ == "__main__":
    unittest.main()
