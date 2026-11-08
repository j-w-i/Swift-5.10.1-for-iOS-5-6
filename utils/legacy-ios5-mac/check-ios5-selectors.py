#!/usr/bin/env python3
"""Find Objective-C selectors a dylib sends that nothing on iOS 5.1.1 implements.

Symbol-level checks cannot see this class of failure: sending a selector to a system
object that does not implement it compiles, links and passes every import check, then
raises `doesNotRecognizeSelector` at run time (the first launch of the matching-runtime
build died this way on `+newTaggedNSStringWithASCIIBytes_:length_:`, a selector that only
exists from iOS 7).

For each image the check reads `__objc_selrefs` (every selector the code can send) and
compares it with the set of method names present anywhere in Apple's iOS 5.1.1 shared
cache (`ios5-reference/ios511-selectors.json.gz`). A selector is acceptable when
  * some iOS 5.1.1 image implements it, or
  * the same image implements it itself (its own method list), or
  * it is listed in the per-image allowlist file with a reason (feature-gated sends).

It is conservative by design: it proves a selector exists *somewhere* on the OS, not that
the particular receiver implements it. A miss is always a real defect; a pass is necessary,
not sufficient.

Usage:
  check-ios5-selectors.py [--allow FILE] DYLIB_OR_EXE ...
  check-ios5-selectors.py [--allow FILE] --runtime-dir DIR
  check-ios5-selectors.py --self-test
Exit codes: 0 pass, 1 unimplemented selector, 2 usage/IO error.
"""
import gzip
import json
import struct
import sys
from pathlib import Path
from armv7slice import select_armv7  # local helper: unwrap fat images to the armv7 slice

HERE = Path(__file__).resolve().parent
REFERENCE = HERE / "ios5-reference" / "ios511-selectors.json.gz"
DEFAULT_ALLOW = HERE / "ios5-reference" / "selector-allowlist.json"
MH_MAGIC = 0xFEEDFACE
CPU_TYPE_ARM = 12


def load_reference(path):
    with gzip.open(path, "rt") as stream:
        return frozenset(json.load(stream))


def load_allowlist(path):
    if not path.is_file():
        return {}
    data = json.loads(path.read_text())
    return {key: value for key, value in data.items() if not key.startswith("_")}


def thin(data):
    if struct.unpack_from(">I", data, 0)[0] == 0xCAFEBABE:
        for index in range(struct.unpack_from(">I", data, 4)[0]):
            cpu, _sub, offset, _size, _align = struct.unpack_from(">5I", data, 8 + 20 * index)
            if cpu == CPU_TYPE_ARM:
                return offset
        raise ValueError("no ARM slice")
    return 0


def sections(data, base):
    header = struct.unpack_from("<7I", data, base)
    if header[0] != MH_MAGIC or header[1] != CPU_TYPE_ARM:
        raise ValueError("expected thin little-endian ARM32 Mach-O")
    result = []
    cursor = base + 28
    for _ in range(header[4]):
        cmd, size = struct.unpack_from("<2I", data, cursor)
        if cmd == 1:
            for index in range(struct.unpack_from("<I", data, cursor + 48)[0]):
                name, _seg, addr, length, offset = struct.unpack_from(
                    "<16s16s3I", data, cursor + 56 + 68 * index)
                result.append((name.rstrip(b"\0").decode(), addr, length, base + offset))
        cursor += size
    return result


def cstring(data, offset):
    return data[offset:data.index(b"\0", offset)].decode("latin1")


def used_and_defined(data):
    """Return (selectors sent, selectors this image implements in its own method lists).

    `__objc_methname` also holds the names of selectors that are merely *sent*, so the
    implemented set is built from the method lists reachable from the class list, the
    category list and the protocol list (instance and class methods, required and
    optional), never from the string pool.
    """
    base = thin(data)
    secs = sections(data, base)

    def to_offset(address):
        for _name, addr, length, offset in secs:
            if addr <= address < addr + length:
                return offset + address - addr
        return None

    def word(address):
        offset = to_offset(address)
        if offset is None or offset + 4 > len(data):
            return None
        return struct.unpack_from("<I", data, offset)[0]

    def text(address):
        offset = to_offset(address)
        return cstring(data, offset) if offset is not None else None

    used = set()
    for name, _addr, length, offset in secs:
        if name == "__objc_selrefs":
            for index in range(length // 4):
                pointer = struct.unpack_from("<I", data, offset + 4 * index)[0]
                target = text(pointer)
                if target is not None:
                    used.add(target)

    defined = set()

    def method_list(address, big=False):
        if not address:
            return
        header, count = word(address), word(address + 4)
        if header is None or count is None or count > 100000:
            return
        entry = (header & 0xFFFC) or 12
        for index in range(count):
            name = word(address + 8 + index * entry)
            if name:
                value = text(name)
                if value:
                    defined.add(value)

    def ro(address):
        if address:
            method_list(word(address + 20))

    def class_methods(class_address):
        data_pointer = word(class_address + 16)
        if data_pointer:
            ro(data_pointer & ~3)

    def protocol(address):
        # protocol_t: isa, name, protocols, instanceMethods, classMethods,
        # optionalInstanceMethods, optionalClassMethods
        for field in (12, 16, 20, 24):
            method_list(word(address + field))

    for name, _addr, length, offset in secs:
        entries = [struct.unpack_from("<I", data, offset + 4 * i)[0] for i in range(length // 4)]
        if name == "__objc_classlist":
            for klass in entries:
                class_methods(klass)
                isa = word(klass)
                if isa:
                    class_methods(isa)
        elif name == "__objc_catlist":
            for category in entries:
                method_list(word(category + 8))
                method_list(word(category + 12))
        elif name == "__objc_protolist":
            for proto in entries:
                protocol(proto)
    return used, defined


def missing(used, implemented, reference, allowed):
    """Selectors not implemented by the OS, by anything we ship, nor explicitly allowed."""
    return sorted(s for s in used
                  if s not in reference and s not in implemented and s not in allowed)


def self_test():
    reference = frozenset({"length", "hash"})
    used = {"length", "newTaggedNSStringWithASCIIBytes_:length_:", "debugQuickLookObject",
            "ourOwnSelector"}
    result = missing(used, {"ourOwnSelector"}, reference,
                     {"debugQuickLookObject": "feature gated"})
    assert result == ["newTaggedNSStringWithASCIIBytes_:length_:"], result
    print("PASS: iOS 5 selector policy self-test")


def main(argv):
    allow_path = DEFAULT_ALLOW
    files = []
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--self-test":
            self_test()
            return 0
        if arg == "--allow":
            allow_path = Path(argv[index + 1]); index += 2; continue
        if arg == "--runtime-dir":
            files.extend(sorted(Path(argv[index + 1]).glob("*.dylib"))); index += 2; continue
        files.append(Path(arg)); index += 1
    if not files:
        print(__doc__)
        return 2
    if not REFERENCE.is_file():
        print("FAIL: missing %s" % REFERENCE)
        return 2
    reference = load_reference(REFERENCE)
    allowlist = load_allowlist(allow_path)
    analysed, failures = [], 0
    for path in files:
        try:
            analysed.append((path, *used_and_defined(select_armv7(path.read_bytes()))))
        except (OSError, ValueError) as error:
            print("FAIL %s: %s" % (path.name, error))
            failures += 1
    # A selector our own runtime implements anywhere in the shipped set is satisfied
    # (for example the Foundation overlay implements what libswiftCore sends).
    implemented = set()
    for _path, _used, defined in analysed:
        implemented |= defined
    for path, used, _defined in analysed:
        allowed = set(allowlist.get(path.name, {})) | set(allowlist.get("*", {}))
        bad = missing(used, implemented, reference, allowed)
        for selector in bad:
            print("FAIL %s: selector '%s' is sent but implemented by no iOS 5.1.1 image "
                  "and by nothing we ship" % (path.name, selector))
        failures += len(bad)
        print("%s %s: %d selectors sent, %d unimplemented"
              % ("FAIL" if bad else "PASS", path.name, len(used), len(bad)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
