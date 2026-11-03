#!/usr/bin/env python3
"""Hand-crafted metadata-only fixtures, NOT runnable runtime product binaries.

Run directly with python3 -B, or via ../check-runtime-deployment.py --self-test.
All filesystem fixtures live under TEST_WORK_ROOT (override with the self-test
--test-work-dir option); no SDK install, patching, or device execution occurs.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / "check-runtime-deployment.py"
spec = importlib.util.spec_from_file_location("runtime_deployment_checker", SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
TEST_WORK_ROOT = Path("/Users/jwalr/Developer/Neocord2-iOS5-Work/sdk-build/runtime-floor-check")
V5 = 0x50000
V7 = 0x70000


def version_command(minimum=V5, command=0x25, endian="<"):
    return struct.pack(endian + "4I", command, 16, minimum, 0xd0700)


def build_command(minimum=V5, platform=2, tools=0, endian="<"):
    return struct.pack(endian + "6I", 0x32, 24, platform, minimum, 0xd0700, tools)


def thin(minimum=V5, subtype=9, cpu=12, kind=6, commands=None, endian="<"):
    if commands is None:
        commands = [version_command(minimum, endian=endian)]
    is64 = bool(cpu & 0x1000000)
    header = struct.pack(endian + "7I", 0xfeedfacf if is64 else 0xfeedface,
                         cpu, subtype, kind, len(commands), sum(map(len, commands)), 0)
    return header + (struct.pack(endian + "I", 0) if is64 else b"") + b"".join(commands)


def fat(parts, fat64=False, endian=">"):
    # Each tuple is (CPU, subtype, thin bytes). No executable sections exist.
    stride = 32 if fat64 else 20
    cursor = 8 + stride * len(parts)
    entries, payload = [], b""
    for cpu, subtype, data in parts:
        padding = (-cursor) % 4
        payload += b"\0" * padding
        cursor += padding
        entries.append(struct.pack(endian + ("IIQQII" if fat64 else "5I"),
                                   cpu, subtype, cursor, len(data), 2, *([0] if fat64 else [])))
        payload += data
        cursor += len(data)
    return struct.pack(endian + "2I", 0xcafebabf if fat64 else 0xcafebabe, len(parts)) + b"".join(entries) + payload


class MetadataTests(unittest.TestCase):
    def audit(self, data, claimed=V5):
        return checker.inspect_macho(data, claimed)

    def reject(self, data, text=None):
        with self.assertRaisesRegex(checker.InvalidMachO, text or "."):
            self.audit(data)

    def test_thin_5_pass(self):
        result = self.audit(thin())
        self.assertTrue(result["passed"])
        self.assertEqual(result["selected_slices"][0]["minimum"], "5.0.0")

    def test_thin_7_fails_with_observed_value(self):
        result = self.audit(thin(V7))
        self.assertFalse(result["passed"])
        self.assertEqual(result["selected_slices"][0]["minimum"], "7.0.0")
        self.assertEqual(result["selected_slices"][0]["sdk"], "13.7.0")

    def test_5_1_fails_claim_5(self):
        self.assertFalse(self.audit(thin(0x50100))["passed"])

    def test_explicit_claim_7_is_not_silently_fixed_to_5(self):
        self.assertTrue(self.audit(thin(V7), V7)["passed"])

    def test_missing_deployment_command(self):
        self.reject(thin(commands=[]), "exactly one")

    def test_wrong_platform_legacy(self):
        for command in (0x24, 0x2f, 0x30):
            with self.subTest(command=command):
                self.reject(thin(commands=[version_command(command=command)]), "wrong platform")

    def test_build_version_ios_pass(self):
        self.assertTrue(self.audit(thin(commands=[build_command()]))["passed"])

    def test_build_version_7_fails(self):
        self.assertFalse(self.audit(thin(commands=[build_command(V7)]))["passed"])

    def test_build_version_wrong_platform(self):
        for platform in (0, 1, 3, 6, 7):
            with self.subTest(platform=platform):
                self.reject(thin(commands=[build_command(platform=platform)]), "wrong platform")

    def test_build_version_tools_bounds(self):
        self.reject(thin(commands=[build_command(tools=1)]), "tool table")
        self.assertTrue(self.audit(thin(commands=[struct.pack("<6I", 0x32, 32, 2, V5, V7, 1)
                                                   + struct.pack("<2I", 1, 0x10000)]))["passed"])

    def test_duplicate_deployment_commands(self):
        self.reject(thin(commands=[version_command(), version_command()]), "exactly one")
        self.reject(thin(commands=[version_command(), build_command()]), "exactly one")

    def test_zero_nonsense_version(self):
        self.reject(thin(0), "zero-major")

    def test_all_header_and_command_truncations(self):
        original = thin()
        for length in range(len(original)):
            with self.subTest(length=length):
                self.reject(original[:length])

    def test_unknown_magic(self):
        self.reject(b"not macho" * 10)

    def test_not_dylib(self):
        for kind in (0, 1, 2, 8):
            with self.subTest(kind=kind):
                self.reject(thin(kind=kind), "MH_DYLIB")

    def test_no_armv7(self):
        self.reject(thin(cpu=checker.ARM64, subtype=0), "no baseline ARMv7")
        self.reject(thin(subtype=11), "no baseline ARMv7")
        self.reject(thin(subtype=12), "no baseline ARMv7")
        self.reject(thin(subtype=6), "no baseline ARMv7")

    def test_arm_capability_flags_rejected(self):
        self.reject(thin(subtype=0x80000009), "capability")

    def test_wrong_header_width(self):
        data = bytearray(thin())
        struct.pack_into("<I", data, 4, checker.ARM64)
        self.reject(data, "width mismatch")

    def test_big_endian_thin(self):
        self.assertTrue(self.audit(thin(endian=">"))["passed"])

    def test_lc_command_size_zero_small_unaligned_and_overrun(self):
        for size in (0, 4, 10, 20, 0xffffffff):
            with self.subTest(size=size):
                data = bytearray(thin())
                struct.pack_into("<I", data, 32, size)
                self.reject(data, "bounds|size")

    def test_lc_version_payload_exact_size(self):
        self.reject(thin(commands=[struct.pack("<2I", 0x25, 8)]), "VERSION_MIN size")
        self.reject(thin(commands=[version_command()[:4] + struct.pack("<I", 20)
                                   + version_command()[8:] + b"\0" * 4]), "VERSION_MIN size")

    def test_lc_count_size_disagreement(self):
        data = bytearray(thin())
        struct.pack_into("<I", data, 16, 2)
        self.reject(data, "count|header")
        struct.pack_into("<I", data, 16, 0)
        self.reject(data, "count/sizeofcmds")

    def test_fat_arm64_7_irrelevant(self):
        for fat64 in (False, True):
            for endian in ("<", ">"):
                with self.subTest(fat64=fat64, endian=endian):
                    data = fat([(checker.ARM64, 0, thin(V7, cpu=checker.ARM64, subtype=0)),
                                (12, 9, thin())], fat64, endian)
                    result = self.audit(data)
                    self.assertTrue(result["passed"])
                    self.assertEqual(len(result["selected_slices"]), 1)

    def test_fat_armv7_7_not_hidden_by_arm64_5(self):
        self.assertFalse(self.audit(fat([(12, 9, thin(V7)),
                                       (checker.ARM64, 0, thin(cpu=checker.ARM64, subtype=0))]))["passed"])

    def test_fat_armv7s_5_1_cannot_hide_behind_armv7_5(self):
        result = self.audit(fat([(12, 9, thin()), (12, 11, thin(0x50100, subtype=11))]))
        self.assertFalse(result["passed"])
        self.assertEqual(result["selected_slices"][1]["architecture"], "armv7s")

    def test_fat_no_baseline_armv7(self):
        self.reject(fat([(checker.ARM64, 0, thin(cpu=checker.ARM64, subtype=0))]), "no baseline")

    def test_fat_all_truncations(self):
        original = fat([(12, 9, thin()), (12, 11, thin(subtype=11))])
        for length in range(len(original)):
            with self.subTest(length=length):
                self.reject(original[:length])

    def test_fat_table_subtype_mismatch(self):
        self.reject(fat([(12, 9, thin(subtype=11))]), "subtype mismatch")

    def test_fat_duplicate_architecture(self):
        self.reject(fat([(12, 9, thin()), (12, 9, thin())]), "duplicate")

    def test_fat_bounds_overlap_alignment(self):
        original = fat([(12, 9, thin()), (12, 11, thin(subtype=11))])
        for field, value, message in ((16, 4, "bounds"), (20, 0xffffffff, "bounds"),
                                      (24, 32, "alignment"), (16, 49, "misaligned")):
            with self.subTest(field=field):
                data = bytearray(original)
                struct.pack_into(">I", data, field, value)
                self.reject(data, message)
        data = bytearray(original)
        struct.pack_into(">I", data, 20, 48)  # first slice extends four bytes into second
        self.reject(data, "overlapping")

    def test_fat64_reserved_and_huge_offsets(self):
        original = fat([(12, 9, thin())], fat64=True)
        data = bytearray(original)
        struct.pack_into(">I", data, 36, 1)
        self.reject(data, "reserved")
        data = bytearray(original)
        struct.pack_into(">Q", data, 16, 0xffffffffffffffff)
        self.reject(data, "bounds")

    def test_versions_input_validation(self):
        self.assertEqual(checker.parse_version("5.0"), V5)
        self.assertEqual(checker.parse_version("5.1.2"), 0x50102)
        for value in ("5", "five", "5.0-beta", "0.0", "5.256", "65536.0", "-5.0", "5.0.256"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                checker.parse_version(value)


class FilesystemTests(unittest.TestCase):
    def setUp(self):
        TEST_WORK_ROOT.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="metadata-fixtures-", dir=str(TEST_WORK_ROOT))
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.runtime = self.root / "runtime"
        self.runtime.mkdir()

    def populate(self, root=None, minimum=V5):
        root = root or self.runtime
        root.mkdir(parents=True, exist_ok=True)
        for name in checker.LIBRARIES:
            (root / name).write_bytes(thin(minimum))

    def args(self, **changes):
        values = dict(runtime_dir=str(self.runtime), toolchain=None, claimed_minimum="5.0",
                      objects_dir=None, command_log=None, compiler_provenance=None, sdk_provenance=None)
        values.update(changes)
        return argparse.Namespace(**values)

    def cli(self, *arguments):
        return subprocess.run([sys.executable, "-B", str(SCRIPT), *map(str, arguments)],
                              text=True, capture_output=True,
                              env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))

    def test_complete_synthetic_runtime_positive_and_hashes(self):
        self.populate()
        report = checker.run_audit(self.args())
        self.assertTrue(report["passed"])
        self.assertIn("NOT runtime API proof", report["notice"])
        self.assertEqual(len(report["libraries"]), 4)
        self.assertEqual(report["libraries"][0]["sha256"], hashlib.sha256(thin()).hexdigest())

    def test_partial_runtime_absence_fails_closed(self):
        (self.runtime / checker.LIBRARIES[0]).write_bytes(thin())
        report = checker.run_audit(self.args())
        self.assertFalse(report["passed"])
        self.assertEqual(sum(item["passed"] for item in report["libraries"]), 1)
        self.assertIn(str(self.runtime / checker.LIBRARIES[1]), report["libraries"][1]["errors"][0])

    def test_core_7_diagnostic_retains_hash_and_values(self):
        self.populate()
        core = self.runtime / checker.LIBRARIES[0]
        core.write_bytes(thin(V7))
        entry = checker.run_audit(self.args())["libraries"][0]
        self.assertFalse(entry["passed"])
        self.assertIn("7.0.0 exceeds claimed 5.0.0", entry["errors"][0])
        self.assertEqual(entry["sha256"], hashlib.sha256(core.read_bytes()).hexdigest())

    def test_toolchain_selects_legacy_not_default(self):
        tc = self.root / "TC"
        self.populate(tc / "usr/lib/swift/iphoneos", minimum=V7)
        self.populate(tc / "usr/lib/swift_ios5/iphoneos")
        self.assertTrue(checker.run_audit(self.args(runtime_dir=None, toolchain=str(tc)))["passed"])
        (tc / "usr/lib/swift_ios5/iphoneos" / checker.LIBRARIES[0]).write_bytes(thin(V7))
        self.populate(tc / "usr/lib/swift/iphoneos")
        self.assertFalse(checker.run_audit(self.args(runtime_dir=None, toolchain=str(tc)))["passed"])

    def test_objects_hash_manifest_and_command_log(self):
        self.populate()
        objects = self.root / "objects"
        objects.mkdir()
        data = thin(kind=1)
        (objects / "fresh.arm32.o").write_bytes(data)
        log = self.root / "commands.log"
        log.write_text("fixture provenance only; not a real compiler build\n")
        report = checker.run_audit(self.args(objects_dir=str(objects), command_log=str(log)))
        self.assertTrue(report["passed"])
        manifest = report["object_provenance"]
        digest = hashlib.sha256(data).hexdigest()
        expected = hashlib.sha256(("fresh.arm32.o\0" + digest + "\n").encode()).hexdigest()
        self.assertEqual(manifest["aggregate_sha256"], expected)
        self.assertEqual(manifest["objects"][0]["sha256"], digest)
        self.assertEqual(report["supplied_provenance"]["command_log"]["sha256"], hashlib.sha256(log.read_bytes()).hexdigest())
        self.assertIn("do not prove freshness", manifest["provenance_notice"])

    def test_old_floor_object_fails_and_preserves_manifest(self):
        objects = self.root / "objects"
        objects.mkdir()
        (objects / "old.arm32.o").write_bytes(thin(V7, kind=1))
        report = checker.audit_objects(objects, V5)
        self.assertFalse(report["passed"])
        self.assertIsNotNone(report["aggregate_sha256"])
        self.assertIn("7.0.0", report["objects"][0]["errors"][0])

    def test_empty_missing_and_symlinked_object_roots_fail(self):
        self.assertFalse(checker.audit_objects(self.root / "absent", V5)["passed"])
        empty = self.root / "empty"
        empty.mkdir()
        self.assertFalse(checker.audit_objects(empty, V5)["passed"])
        (empty / "escape").symlink_to(self.runtime, target_is_directory=True)
        self.assertIn("symlinked", checker.audit_objects(empty, V5)["errors"][0])

    def test_missing_optional_provenance_fails_not_invented(self):
        self.populate()
        report = checker.run_audit(self.args(sdk_provenance=str(self.root / "no-sdk-data")))
        self.assertFalse(report["passed"])
        self.assertNotIn("sdk_provenance", report["supplied_provenance"])

    def test_cli_new_report_only_and_no_input_mutation(self):
        self.populate()
        output = self.root / "report.json"
        before = {p: p.read_bytes() for p in self.runtime.iterdir()}
        result = self.cli("--runtime-dir", self.runtime, "--output", output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(output.read_text())["passed"])
        self.assertEqual(before, {p: p.read_bytes() for p in self.runtime.iterdir()})
        original = output.read_bytes()
        result = self.cli("--runtime-dir", self.runtime, "--output", output)
        self.assertEqual(result.returncode, 2)
        self.assertIn("refusing to overwrite", result.stderr)
        self.assertEqual(original, output.read_bytes())

    def test_cli_expected_negative_report_exit_one(self):
        self.populate(minimum=V7)
        output = self.root / "negative.json"
        result = self.cli("--runtime-dir", self.runtime, "--output", output)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("7.0.0 exceeds claimed 5.0.0", result.stderr)
        self.assertFalse(json.loads(output.read_text())["passed"])

    def test_cli_requires_explicit_inputs_and_new_output(self):
        for arguments in ([], ["--runtime-dir", self.runtime], ["--output", self.root / "a.json"],
                          ["--toolchain", self.root, "--runtime-dir", self.runtime, "--output", self.root / "a.json"]):
            with self.subTest(arguments=arguments):
                self.assertEqual(self.cli(*arguments).returncode, 2)

    def test_scan_limit_fails_closed(self):
        objects = self.root / "objects"
        objects.mkdir()
        (objects / "fresh.arm32.o").write_bytes(thin(kind=1))
        previous = checker.MAX_SCAN_ENTRIES
        try:
            checker.MAX_SCAN_ENTRIES = 0
            self.assertIn("scan exceeds", checker.audit_objects(objects, V5)["errors"][0])
        finally:
            checker.MAX_SCAN_ENTRIES = previous


if __name__ == "__main__":
    unittest.main(verbosity=2)
