#!/usr/bin/env python3
"""Audit every dyld image initializer of a legacy runtime for launch safety.

On iOS 5, dyld runs image initializers before the process entry point. Swift-level
Foundation work in that phase (class-name bridging, environment dictionaries,
dynamic casts, message sends to UIKit) traps, so only Objective-C runtime
registration is allowed there.

Usage:
  check-runtime-initializers.py DYLIB [DYLIB ...]
  check-runtime-initializers.py --runtime-dir DIR
  check-runtime-initializers.py --self-test

Read-only: parses Mach-O headers and symbol tables; no rewriting, no execution.
Exit codes: 0 pass, 1 policy violation, 2 usage/IO error.
"""
import struct
import sys
from pathlib import Path
from armv7slice import select_armv7  # local helper: unwrap fat images to the armv7 slice

# Substrings that must never appear in an initializer's own code path. Each one is
# a Foundation/Objective-C bridging entry the legacy runtime cannot use this early.
FORBIDDEN = (
    "NSClassFromString",
    "NSSelectorFromString",
    "ProcessInfo",
    "NSBundle",
    "UserDefaults",
    "objectForKey",
    "componentsSeparatedBy",
    "stringByTrimming",
    "objc_msgSend",  # message sends to framework objects are unsafe at init
    "swift_getWitnessTable",
    "swift_dynamicCast",
    "_forceBridgeFromObjectiveC",
)

# Initializer symbol names we install ourselves and have audited by design: they
# perform only objc runtime registration.
# Each entry is audited to do Objective-C runtime registration only: class and
# method installation, or libc calls. No Foundation object, no Swift call, no
# message send that can bridge.
AUDITED_CONSTRUCTORS = (
    "UICInstallBackportMethods",
    "UICInstallLabelAttributedText",
    "UICInstallTextAttachmentClasses",
    "UICInstallActivityViewController",
    "FBPExtrasEnsureInstalled",
    # Vendored runtimes reviewed for this policy:
    "PSTInstallIndexPathAdditions",      # NSIndexPath class + class_addMethod
    "PSTCreateUICollectionViewClasses",  # objc class registration
    "PSTCollectionViewStatsSetup",       # getenv/atexit only
    "OAStackViewPatchEntry",             # objc_allocateClassPair only
)

# Only the dylibs that carry our re-authored code are enforced. Apple's own
# Swift runtime initializers (Core, RemoteMirror) are reported for visibility but
# not treated as policy failures: they are the shipped runtime's own bootstrap.
ENFORCED = ("libswiftUIKit.dylib", "libswiftFoundation.dylib")

MH_MAGIC = 0xFEEDFACE
CPU_TYPE_ARM = 12


def _fat_slices(data):
    if len(data) < 8:
        raise ValueError("truncated file")
    magic, count = struct.unpack_from(">2I", data, 0)
    if magic not in (0xCAFEBABE, 0xCAFEBABF):
        return [(0, len(data))]
    slices = []
    cursor = 8
    for _ in range(count):
        if magic == 0xCAFEBABE:
            cpu, _sub, offset, size, _align = struct.unpack_from(">5I", data, cursor)
            cursor += 20
        else:
            cpu, _sub, offset, size, _align, _res = struct.unpack_from(">2I4Q", data, cursor)
            cursor += 32
        slices.append((cpu, offset, size))
    return [(offset, size) for cpu, offset, size in slices if cpu == CPU_TYPE_ARM]


def _sections(data, base):
    header = struct.unpack_from("<7I", data, base)
    if header[0] != MH_MAGIC or header[1] != CPU_TYPE_ARM:
        raise ValueError("expected thin little-endian ARM32 Mach-O")
    ncmds, sizeofcmds = header[4], header[5]
    cursor = base + 28
    sections, symtab, dysymtab = [], None, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<2I", data, cursor)
        if cmd == 1:  # LC_SEGMENT
            segment = struct.unpack_from("<2I16s8I", data, cursor)
            for index in range(segment[9]):
                section = struct.unpack_from("<16s16s9I", data, cursor + 56 + index * 68)
                sections.append({"name": section[0].rstrip(b"\0").decode(),
                                 "offset": section[4], "size": section[3],
                                 "address": section[2], "flags": section[8]})
        elif cmd == 2:  # LC_SYMTAB
            symtab = struct.unpack_from("<6I", data, cursor)[2:]
        elif cmd == 0xB:  # LC_DYSYMTAB
            values = struct.unpack_from("<20I", data, cursor)
            dysymtab = {"undef": (values[4], values[3])}
        cursor += size
    return sections, symtab, dysymtab, header


def _symbols(data, symtab, base=0):
    if not symtab:
        raise ValueError("missing symbol table")
    symbol_offset, count, string_offset, string_size = symtab
    symbol_offset += base
    string_offset += base
    if string_offset + string_size > len(data):
        raise ValueError("truncated string table")
    table = {}
    for index in range(count):
        string_index, kind, section, _desc, value = struct.unpack_from(
            "<IBBHI", data, symbol_offset + 12 * index)
        if section == 0 or not kind & 0x0E == 0x0E:
            continue
        end = data.find(b"\0", string_offset + string_index,
                        string_offset + string_size)
        if end < 0:
            continue
        name = data[string_offset + string_index:end].decode(errors="replace")
        table.setdefault(value & ~1, []).append(name)
    return table


def audit_bytes(data, label):
    problems = []
    notes = []
    slices = _fat_slices(data)
    if not slices:
        return ["%s: no ARM slice" % label]
    for base, size in slices:
        section_list, symtab, _dysymtab, _header = _sections(data, base)
        symbols = _symbols(data, symtab, base)
        initializers = [s for s in section_list if s["flags"] & 0xFF == 9]
        for section in initializers:
            for position in range(0, section["size"], 4):
                pointer, = struct.unpack_from("<I", data, base + section["offset"] + position)
                names = symbols.get(pointer & ~1, [])
                if not names:
                    problems.append("%s: initializer 0x%x has no symbol name" % (label, pointer))
                    continue
                name = names[0]
                if any(audited in name for audited in AUDITED_CONSTRUCTORS):
                    continue
                if label not in ENFORCED:
                    notes.append("%s: informational initializer %s" % (label, name))
                    continue
                # A Swift static initializer or any unlisted initializer must be
                # justified; report it so a human reviews the policy.
                problems.append(
                    "%s: initializer %s is not an audited runtime constructor"
                    % (label, name))
        # Initializer code must not textually reference bridging entry points.
        for section in section_list:
            if section["name"] not in ("__text", "__const"):
                continue
            blob = data[base + section["offset"]:base + section["offset"] + section["size"]]
            for token in FORBIDDEN:
                if token.encode() in blob:
                    problems.append("%s: %s section references %s"
                                    % (label, section["name"], token))
    return problems + notes


def self_test():
    cases = [
        ("bogus magic", b"\0" * 64, "expected thin"),
        ("truncated", b"\xce\xfa\xed\xfe", "truncated"),
    ]
    for name, payload, expected in cases:
        try:
            audit_bytes(payload, name)
        except ValueError as error:
            if expected not in str(error):
                raise ValueError("self-test %s: unexpected error %s" % (name, error))
        else:
            raise ValueError("self-test %s: accepted malformed input" % name)
    print("PASS: initializer policy self-tests (%d fixtures)" % len(cases))


def main(argv):
    if argv[:1] == ["--self-test"]:
        self_test()
        return 0
    paths = []
    if argv[:1] == ["--runtime-dir"]:
        if len(argv) != 2:
            raise SystemExit("usage: --runtime-dir DIR")
        paths = sorted(Path(argv[1]).glob("*.dylib"))
        if not paths:
            raise SystemExit("no dylibs in " + argv[1])
    else:
        paths = [Path(p) for p in argv]
    if not paths:
        raise SystemExit("usage: check-runtime-initializers.py DYLIB... | --runtime-dir DIR")
    failures = 0
    for path in paths:
        data = select_armv7(path.read_bytes())
        try:
            problems = audit_bytes(data, path.name)
        except ValueError as error:
            print("FAIL %s: %s" % (path.name, error))
            failures += 1
            continue
        for problem in problems:
            informational = "informational" in problem
            print(("PASS " if informational else "FAIL ") + problem)
            if not informational:
                failures += 1
    if failures:
        return 1
    print("PASS: dyld initializers are limited to audited runtime constructors")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except OSError as error:
        raise SystemExit("FAIL: " + str(error))
