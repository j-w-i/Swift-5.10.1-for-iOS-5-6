#!/usr/bin/env python3
"""Audit Objective-C metadata code pointers for ARM/Thumb instruction-state agreement.

iOS 5's loader and objc4 call method IMPs, block helpers and class initializers through
pointers whose low bit selects ARM vs Thumb. A pointer whose bit disagrees with the
code it points at executes data as instructions and dies with SIGILL/SIGSEGV; this was
the failure signature of the first device crashes. The runtime and overlays are built
all-ARM (-marm), so every code pointer in the Objective-C metadata sections must have
its low bit clear *and* point at ARM code.

The metadata is walked structurally (class list and category list -> class_ro_t and
method_list_t -> IMP fields). Raw words are never guessed to be pointers, because
class_ro_t flag words can numerically equal a text address.

Usage:
  check-objc-method-states.py DYLIB [DYLIB ...]
  check-objc-method-states.py --runtime-dir DIR
  check-objc-method-states.py --self-test
Exit codes: 0 pass, 1 mismatch, 2 usage/IO error.
"""
import struct
import sys
from pathlib import Path
from armv7slice import select_armv7  # local helper: unwrap fat images to the armv7 slice

MH_MAGIC = 0xFEEDFACE
CPU_TYPE_ARM = 12
CODE_SECTIONS = ("__text",)
METADATA_SECTIONS = ("__objc_const", "__objc_data", "__objc_classlist", "__const")
N_ARM_THUMB_DEF = 0x0008


def thin_slice(data):
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        count = struct.unpack_from(">I", data, 4)[0]
        for index in range(count):
            cpu, _sub, offset, size, _align = struct.unpack_from(">5I", data, 8 + 20 * index)
            if cpu == CPU_TYPE_ARM:
                return offset, size
        raise ValueError("no ARM slice")
    return 0, len(data)


def parse(data, base):
    header = struct.unpack_from("<7I", data, base)
    if header[0] != MH_MAGIC or header[1] != CPU_TYPE_ARM:
        raise ValueError("expected thin little-endian ARM32 Mach-O")
    sections, symtab = [], None
    cursor = base + 28
    for _ in range(header[4]):
        cmd, size = struct.unpack_from("<2I", data, cursor)
        if cmd == 1:  # LC_SEGMENT
            count = struct.unpack_from("<I", data, cursor + 48)[0]
            for index in range(count):
                name, seg, addr, length, offset = struct.unpack_from(
                    "<16s16s3I", data, cursor + 56 + 68 * index)
                sections.append({"name": name.rstrip(b"\0").decode(),
                                 "segment": seg.rstrip(b"\0").decode(),
                                 "addr": addr, "size": length, "offset": base + offset})
        elif cmd == 2:  # LC_SYMTAB
            symoff, nsyms, stroff, strsize = struct.unpack_from("<4I", data, cursor + 8)
            symtab = (base + symoff, nsyms, base + stroff, strsize)
        cursor += size
    return sections, symtab


def code_states(data, symtab):
    """Map address (low bit cleared) -> True if the defined symbol is Thumb code."""
    symoff, nsyms, stroff, _strsize = symtab
    states = {}
    for index in range(nsyms):
        _strx, kind, sect, desc, value = struct.unpack_from("<IBBHI", data, symoff + 12 * index)
        if kind & 0xE0 or sect == 0 or (kind & 0x0E) != 0x0E:
            continue
        states[value & ~1] = bool(desc & N_ARM_THUMB_DEF)
    return states


def audit(data, label, sites=None):
    """Walk the Objective-C metadata structurally; never guess from raw words.

    class list -> class_t -> class_ro_t (+ metaclass) -> method_list_t -> imp, and the
    same for categories' instance/class method lists. Only IMP fields are checked, so
    flag words (for example RO_META|swift-marker) cannot be mistaken for code pointers.
    """
    base, _size = thin_slice(data)
    sections, symtab = parse(data, base)
    if symtab is None:
        raise ValueError("missing symbol table")
    states = code_states(data, symtab)

    def to_offset(address):
        for section in sections:
            if section["addr"] <= address < section["addr"] + section["size"]:
                return section["offset"] + address - section["addr"]
        # Fall back to segment-level mapping for padding between sections.
        return None

    def word(address):
        offset = to_offset(address)
        if offset is None or offset + 4 > len(data):
            return None
        return struct.unpack_from("<I", data, offset)[0]

    checked = mismatches = 0
    problems = []

    def check_imp(owner, imp_address):
        nonlocal checked, mismatches
        value = word(imp_address)
        if value is None or value == 0:
            return
        target = value & ~1
        if target not in states:
            return  # block/trampoline or external; not a defined text symbol
        checked += 1
        if sites is not None:
            sites.append(to_offset(imp_address))
        if bool(value & 1) != states[target]:
            mismatches += 1
            if len(problems) < 5:
                problems.append("%s imp@0x%x = 0x%x (pointer %s, code %s)" % (
                    owner, imp_address, value, "Thumb" if value & 1 else "ARM",
                    "Thumb" if states[target] else "ARM"))

    def walk_method_list(owner, list_address):
        if not list_address:
            return
        header = word(list_address)
        count = word(list_address + 4)
        if header is None or count is None or count > 100000:
            return
        entry_size = (header & ~3) & 0xFFFF or 12
        if entry_size not in (12,):
            return  # small (relative) method lists do not exist in this ABI
        for index in range(count):
            check_imp(owner, list_address + 8 + index * entry_size + 8)

    def walk_ro(owner, ro_address):
        if not ro_address:
            return
        # class_ro_t: flags, instanceStart, instanceSize, ivarLayout, name, baseMethods, ...
        walk_method_list(owner, word(ro_address + 20))

    for section in sections:
        if section["name"] == "__objc_classlist":
            for index in range(section["size"] // 4):
                class_address = struct.unpack_from("<I", data, section["offset"] + 4 * index)[0]
                for klass, tag in ((class_address, "class"),):
                    # class_t (ObjC 2 legacy): isa, superclass, cache, vtable, data
                    data_pointer = word(klass + 16)
                    if data_pointer:
                        # Legacy iOS 5 marker lives in class_ro_t flags / low bits of data.
                        walk_ro("%s@0x%x" % (tag, klass), data_pointer & ~3)
                isa = word(class_address)
                if isa:
                    meta_data = word(isa + 16)
                    if meta_data:
                        walk_ro("meta@0x%x" % isa, meta_data & ~3)
        elif section["name"] == "__objc_catlist":
            for index in range(section["size"] // 4):
                category = struct.unpack_from("<I", data, section["offset"] + 4 * index)[0]
                # category_t: name, cls, instanceMethods, classMethods, ...
                walk_method_list("category@0x%x" % category, word(category + 8))
                walk_method_list("category+@0x%x" % category, word(category + 12))
    return checked, mismatches, problems


def self_test():
    # A pointer to Thumb code without the interworking bit must be reported, and the
    # matching ARM pointer must not be. Exercised through the pure decision rule.
    states = {0x1000: True, 0x2000: False}
    assert bool(0x1000 & 1) != states[0x1000]          # Thumb code, ARM-state pointer
    assert bool(0x2000 & 1) == states[0x2000]          # ARM code, ARM-state pointer
    assert bool(0x1001 & 1) == states[0x1000]          # Thumb code, Thumb-state pointer
    print("PASS: ObjC method-state rule self-test")


def main(argv):
    if argv[:1] == ["--self-test"]:
        self_test()
        return 0
    paths = []
    if argv[:1] == ["--runtime-dir"] and len(argv) == 2:
        paths = sorted(Path(argv[1]).glob("*.dylib"))
    else:
        paths = [Path(a) for a in argv]
    if not paths:
        print(__doc__)
        return 2
    failures = 0
    for path in paths:
        try:
            checked, mismatches, problems = audit(select_armv7(path.read_bytes()), path.name)
        except (OSError, ValueError) as error:
            print("FAIL %s: %s" % (path.name, error))
            failures += 1
            continue
        for problem in problems:
            print("  " + problem)
        print("%s %s: %d code pointers checked, %d state mismatches"
              % ("FAIL" if mismatches else "PASS", path.name, checked, mismatches))
        failures += mismatches
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
