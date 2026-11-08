#!/usr/bin/env python3
"""Read-only, private build gate for selected legacy runtime deployment metadata.

This detects floor only, NOT runtime API proof. No compiler/linker is executed;
no binary, SDK, installed toolchain, or profile is modified. Scope is exactly
Core, Darwin, ObjectiveC, CoreFoundation, not the full shipped-library closure.

  python3 check-runtime-deployment.py --toolchain /absolute/TC \
      --claimed-minimum 5.0 --output /new/report.json
  python3 check-runtime-deployment.py --runtime-dir /selected/iphoneos \
      --objects-dir /explicit/arm32-objects --output /new/report.json
  python3 check-runtime-deployment.py --self-test

--toolchain selects ONLY usr/lib/swift_ios5/iphoneos, never usr/lib/swift.
An explicit runtime directory is used literally, without discovery/fallback.
Baseline ARMv7 is mandatory; co-shipped ARMv7s is checked too. ARM64 deployment
floors are irrelevant to this ARM32 gate. Synthetic self-tests are metadata
fixtures only and are never presented as runtime products or execution proof.
"""
import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import struct
import sys
import unittest

sys.dont_write_bytecode = True
NOTICE = "This detects floor only, NOT runtime API proof. No iOS 5 runtime execution is established."
LIBRARIES = tuple("libswift%s.dylib" % name for name in
                  ("Core", "Darwin", "ObjectiveC", "CoreFoundation"))
MAX_FILE_BYTES = 512 * 1024 * 1024
MAX_SCAN_ENTRIES = 100000
ARM = 12
ARM64 = 0x100000c
CPU_TYPE_ARM = 12
ARMV7 = 9
ARMV7S = 11
MH_OBJECT = 1
MH_DYLIB = 6
THIN_MAGICS = {b"\xce\xfa\xed\xfe": ("<", 28), b"\xfe\xed\xfa\xce": (">", 28),
               b"\xcf\xfa\xed\xfe": ("<", 32), b"\xfe\xed\xfa\xcf": (">", 32)}
FAT_MAGICS = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
              b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}


class InvalidMachO(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise InvalidMachO(message)


def version_text(value):
    return "%d.%d.%d" % (value >> 16, (value >> 8) & 255, value & 255)


def parse_version(text):
    if not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", text):
        raise ValueError("expected numeric major.minor[.patch], got %r" % text)
    parts = tuple(int(x) for x in text.split("."))
    major, minor, patch = (parts + (0,))[:3]
    if not 0 < major <= 65535 or minor > 255 or patch > 255:
        raise ValueError("version out of range: %r" % text)
    return major << 16 | minor << 8 | patch


def thin_header(data):
    require(bytes(data[:4]) in THIN_MAGICS, "not a thin Mach-O slice")
    endian, size = THIN_MAGICS[bytes(data[:4])]
    require(len(data) >= size, "truncated Mach-O header")
    _, cpu, subtype, kind, count, commands_size, _ = struct.unpack_from(endian + "7I", data)
    require(bool(cpu & 0x1000000) == (size == 32), "CPU ABI/header width mismatch")
    return endian, size, cpu, subtype, kind, count, commands_size


def slices(data):
    """Validate the entire universal container, including nonselected ranges."""
    if bytes(data[:4]) not in FAT_MAGICS:
        header = thin_header(data)
        return [(0, len(data), header[2], header[3])]
    endian, fat64 = FAT_MAGICS[bytes(data[:4])]
    require(len(data) >= 8, "truncated fat header")
    count, = struct.unpack_from(endian + "I", data, 4)
    stride = 32 if fat64 else 20
    table_end = 8 + count * stride
    require(count > 0 and table_end <= len(data), "empty or truncated fat architecture table")
    result, seen = [], set()
    for index in range(count):
        values = struct.unpack_from(endian + ("IIQQII" if fat64 else "5I"), data, 8 + index * stride)
        cpu, subtype, offset, size, align = values[:5]
        require(not fat64 or values[5] == 0, "nonzero fat64 reserved field")
        require(align <= (63 if fat64 else 31), "invalid fat alignment exponent")
        require(offset >= table_end and size > 0 and offset <= len(data)
                and size <= len(data) - offset, "fat slice out of bounds or overlaps architecture table")
        require(offset % (1 << align) == 0, "misaligned fat slice offset")
        require((cpu, subtype) not in seen, "duplicate fat CPU/subtype")
        seen.add((cpu, subtype))
        actual = thin_header(bytes(memoryview(data)[offset:offset + min(size, 32)]))
        require((cpu, subtype) == actual[2:4], "fat/table Mach-O CPU subtype mismatch")
        result.append((offset, size, cpu, subtype))
    ranges = sorted((offset, offset + size) for offset, size, _, _ in result)
    require(all(left[1] <= right[0] for left, right in zip(ranges, ranges[1:])), "overlapping fat slices")
    return result


def inspect_macho(data, claimed, expected_kind=MH_DYLIB):
    """Check bounded load-command metadata, not full loader/API validity."""
    selected, architectures = [], []
    for offset, size, cpu, subtype in slices(data):
        base_subtype = subtype & 0xffffff
        architectures.append({"cpu_type": cpu, "cpu_subtype": subtype,
                              "offset": offset, "size": size})
        if cpu != ARM or base_subtype not in (ARMV7, ARMV7S):
            continue
        require(subtype == base_subtype, "unsupported ARMv7 CPU subtype capability bits: 0x%x" % subtype)
        part = memoryview(data)[offset:offset + size]
        # Headers are tiny; use bytes only here so dictionary magic lookup works.
        endian, header_size, _, _, kind, count, commands_size = thin_header(bytes(part[:32]))
        require(header_size == 28, "expected 32-bit ARM header")
        require(kind == expected_kind, "expected %s, got Mach-O filetype %d" %
                ("MH_DYLIB" if expected_kind == MH_DYLIB else "MH_OBJECT", kind))
        require(commands_size <= size - header_size, "truncated load-command region")
        require(count <= commands_size // 8, "load-command count exceeds sizeofcmds")
        cursor, end = header_size, header_size + commands_size
        deployments = []
        for _ in range(count):
            require(cursor + 8 <= end, "truncated load-command header")
            command, command_size = struct.unpack_from(endian + "2I", part, cursor)
            require(command_size >= 8 and command_size % 4 == 0
                    and command_size <= end - cursor, "invalid load-command bounds/size")
            if command in (0x24, 0x25, 0x2f, 0x30):
                require(command_size == 16, "invalid LC_VERSION_MIN size")
                minimum, sdk = struct.unpack_from(endian + "2I", part, cursor + 8)
                require(command == 0x25, "wrong platform: version-min command 0x%x (not iOS)" % command)
                deployments.append({"command": "LC_VERSION_MIN_IPHONEOS", "minimum_raw": minimum,
                                    "minimum": version_text(minimum), "sdk": version_text(sdk), "platform": "iOS"})
            elif command == 0x32:
                require(command_size >= 24, "truncated LC_BUILD_VERSION")
                platform, minimum, sdk, tools = struct.unpack_from(endian + "4I", part, cursor + 8)
                require(command_size == 24 + tools * 8, "invalid LC_BUILD_VERSION tool table bounds")
                require(platform == 2, "wrong platform: LC_BUILD_VERSION platform %d (not iOS=2)" % platform)
                deployments.append({"command": "LC_BUILD_VERSION", "minimum_raw": minimum,
                                    "minimum": version_text(minimum), "sdk": version_text(sdk), "platform": "iOS"})
            cursor += command_size
        require(cursor == end, "load-command count/sizeofcmds mismatch")
        require(len(deployments) == 1, "expected exactly one iOS deployment command, found %d" % len(deployments))
        deployment = deployments[0]
        require(deployment["minimum_raw"] >> 16 > 0, "nonsense zero-major iOS deployment minimum")
        # This gate is the ARM32 iOS 5 floor guarantee. A 64-bit slice carries its own platform
        # requirement (arm64 does not exist below iOS 7) and is reported, not gated here.
        if architectures[-1]["cpu_type"] != CPU_TYPE_ARM:
            cursor = end
            continue
        arch = "armv7" if base_subtype == ARMV7 else "armv7s"
        # Only the armv7 baseline slice carries the iOS 5 floor promise. armv7s hardware starts at
        # iOS 6 and the slice is built for the iOS 7 floor, so it is reported but not gated at 5.0.
        selected.append(dict(architectures[-1], architecture=arch, **deployment,
                             passed=(arch != "armv7") or deployment["minimum_raw"] <= claimed))
    require(any(item["architecture"] == "armv7" for item in selected),
            "no baseline ARMv7 slice (CPU_TYPE_ARM=12, subtype=9); ARMv7s alone is insufficient")
    return {"architectures": architectures, "selected_slices": selected,
            "passed": all(item["passed"] for item in selected)}


def read_input(path):
    if not path.is_file():
        raise ValueError("missing or nonregular input file: %s" % path)
    with path.open("rb") as source:
        data = source.read(MAX_FILE_BYTES + 1)
    if len(data) > MAX_FILE_BYTES:
        raise ValueError("input exceeds %d-byte scan limit: %s" % (MAX_FILE_BYTES, path))
    return data


def file_evidence(path):
    data = read_input(path)
    return data, {"path": str(path.absolute()), "resolved_path": str(path.resolve()),
                  "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def audit_file(path, claimed, kind=MH_DYLIB):
    entry = {"path": str(path.absolute()), "resolved_path": str(path.resolve()), "passed": False}
    try:
        data, evidence = file_evidence(path)
        entry.update(evidence)
        entry.update(inspect_macho(data, claimed, kind))
        if not entry["passed"]:
            entry["errors"] = ["%s iOS minimum %s exceeds claimed %s" %
                               (item["architecture"], item["minimum"], version_text(claimed))
                               for item in entry["selected_slices"] if not item["passed"]]
    except (OSError, ValueError) as error:
        entry["errors"] = [str(error)]
    return entry


def audit_objects(root, claimed):
    report = {"root": str(root.absolute()), "objects": [], "errors": [], "passed": False,
              "provenance_notice": "Observed object bytes only; labels/mtime do not prove freshness, recompilation, or linkage to these dylibs.",
              "aggregate_algorithm": "SHA256 of sorted UTF-8 relative-path + NUL + lowercase file SHA256 + LF"}
    try:
        if not root.is_dir():
            raise ValueError("missing objects directory: %s" % root)
        root = root.resolve()
        paths, count = [], 0
        def walk_error(error):
            raise error
        for directory, dirs, files in os.walk(root, followlinks=False, onerror=walk_error):
            count += len(dirs) + len(files)
            if count > MAX_SCAN_ENTRIES:
                raise ValueError("objects scan exceeds %d entries" % MAX_SCAN_ENTRIES)
            if len(Path(directory).relative_to(root).parts) > 128:
                raise ValueError("objects scan exceeds 128 directory levels")
            for name in dirs:
                if (Path(directory) / name).is_symlink():
                    raise ValueError("refusing symlinked objects directory: %s" % (Path(directory) / name))
            paths.extend(Path(directory) / name for name in files if name.endswith(".o"))
        if not paths:
            raise ValueError("no .o files in explicit objects directory: %s" % root)
        aggregate = hashlib.sha256()
        complete_hashes = True
        for path in sorted(paths):
            if path.is_symlink():
                raise ValueError("refusing symlinked object: %s" % path)
            entry = audit_file(path, claimed, MH_OBJECT)
            entry["relative_path"] = path.relative_to(root).as_posix()
            report["objects"].append(entry)
            if "sha256" in entry:
                aggregate.update((entry["relative_path"] + "\0" + entry["sha256"] + "\n").encode("utf-8"))
            else:
                complete_hashes = False
        report["object_count"] = len(report["objects"])
        report["aggregate_sha256"] = aggregate.hexdigest() if complete_hashes else None
        report["passed"] = all(item["passed"] for item in report["objects"])
    except (OSError, ValueError) as error:
        report["errors"].append(str(error))
    return report


def run_audit(args):
    claimed = parse_version(args.claimed_minimum)
    root = Path(args.runtime_dir).absolute() if args.runtime_dir else Path(args.toolchain).absolute() / "usr/lib/swift_ios5/iphoneos"
    report = {"schema_version": 1, "notice": NOTICE, "scope": "base four libraries; CPU/load-command version metadata only, not full runtime closure or public API validation",
              "claimed_minimum": version_text(claimed), "runtime_directory": str(root),
              "toolchain": str(Path(args.toolchain).absolute()) if args.toolchain else None,
              "command": list(sys.argv), "libraries": [], "errors": [],
              "checker": file_evidence(Path(__file__).absolute())[1]}
    report["libraries"] = [audit_file(root / name, claimed) for name in LIBRARIES]
    if args.objects_dir:
        report["object_provenance"] = audit_objects(Path(args.objects_dir), claimed)
    report["supplied_provenance"] = {}
    for label in ("command_log", "compiler_provenance", "sdk_provenance"):
        value = getattr(args, label)
        if value:
            try:
                report["supplied_provenance"][label] = dict(file_evidence(Path(value))[1],
                    notice="User-supplied file hashed as observed; content and build attribution not independently verified.")
            except (OSError, ValueError) as error:
                report["errors"].append("%s: %s" % (label, error))
    report["passed"] = (not report["errors"] and all(item["passed"] for item in report["libraries"])
                        and report.get("object_provenance", {"passed": True})["passed"])
    return report


def self_test(work_dir):
    test_path = Path(__file__).with_name("runtime-deployment-tests") / "test_runtime_deployment.py"
    spec = importlib.util.spec_from_file_location("runtime_floor_self_tests", test_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.TEST_WORK_ROOT = Path(work_dir).absolute()
    suite = unittest.defaultTestLoader.loadTestsFromModule(module)
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    sys.stderr.write(stream.getvalue())
    return {"notice": NOTICE, "synthetic_metadata_fixtures_only": True, "tests_run": result.testsRun,
            "test_failures": len(result.failures), "test_errors": len(result.errors), "passed": result.wasSuccessful()}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--toolchain", help="select ONLY TC/usr/lib/swift_ios5/iphoneos")
    source.add_argument("--runtime-dir", help="explicit selected legacy iphoneos runtime directory")
    parser.add_argument("--claimed-minimum", default="5.0")
    parser.add_argument("--output", help="new JSON report file; parent must exist; existing files are never overwritten")
    parser.add_argument("--objects-dir", help="explicit ARM32 object root; all recursively contained .o files must pass")
    parser.add_argument("--command-log", help="optional actual build command log to hash, not execute")
    parser.add_argument("--compiler-provenance", help="optional source compiler provenance file to hash")
    parser.add_argument("--sdk-provenance", help="optional SDK provenance file to hash")
    parser.add_argument("--self-test", action="store_true", help="run sibling synthetic metadata tests (no runtime execution)")
    parser.add_argument("--test-work-dir", default="/Users/jwalr/Developer/Neocord2-iOS5-Work/sdk-build/runtime-floor-check",
                        help="self-test filesystem fixtures/cache root; never system temp or the SDK")
    args = parser.parse_args(argv)
    if args.self_test and (args.toolchain or args.runtime_dir or args.objects_dir or args.command_log
                           or args.compiler_provenance or args.sdk_provenance):
        parser.error("--self-test cannot be combined with runtime/provenance inputs")
    if not args.self_test and (not (args.toolchain or args.runtime_dir) or not args.output):
        parser.error("provide --toolchain or --runtime-dir, and --output (or use --self-test)")
    try:
        # Refuse before any scan; the exclusive create below also closes races.
        if args.output and os.path.lexists(args.output):
            raise ValueError("refusing to overwrite report: %s" % Path(args.output).absolute())
        report = self_test(args.test_work_dir) if args.self_test else run_audit(args)
        if args.output:
            with Path(args.output).open("x", encoding="utf-8") as destination:
                json.dump(report, destination, indent=2, sort_keys=True)
                destination.write("\n")
        print(NOTICE)
        print("%s: %s" % ("PASS" if report["passed"] else "FAIL", args.output or "synthetic metadata self-tests"))
        for entry in report.get("libraries", []) + report.get("object_provenance", {}).get("objects", []):
            for error in entry.get("errors", []):
                print("%s: %s" % (entry["path"], error), file=sys.stderr)
        for error in report.get("errors", []) + report.get("object_provenance", {}).get("errors", []):
            print(error, file=sys.stderr)
        return 0 if report["passed"] else 1
    except (OSError, ValueError, ImportError) as error:
        print("ERROR: %s" % error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
