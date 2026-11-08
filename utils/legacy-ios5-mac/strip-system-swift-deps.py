#!/usr/bin/env python3
"""Neutralise weak /usr/lib/swift/* load commands in a Mach-O image.

The 64-bit backport slices inherit weak autolinks to modern SDK overlay dylibs
(for example libswiftCoreMIDI.dylib). Those dylibs do not exist on the iOS 7
floor. Loading them where they do exist would mix the system Swift runtime with
the stdlib embedded in the app, which is an ABI hazard, so the dependency is
removed instead of satisfied.

Only LC_LOAD_WEAK_DYLIB entries pointing into /usr/lib/swift/ are touched. The
load command is retyped to an unused id with the same size, so no offset in the
file moves and no code or symbol table entry changes. A *strong* dependency on
/usr/lib/swift/ is a hard error: it means the slice really does require the
system runtime and cannot be shipped.

Usage: strip-system-swift-deps.py IMAGE [IMAGE...]
Exit: 0 stripped or nothing to do; 1 strong dependency found; 2 malformed input.
"""
import os
import struct
import subprocess
import sys

LC_SYMTAB = 0x2
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
UNUSED_CMD = 0x1F01
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
FAT_MAGIC_64 = 0xCAFEBABF
FAT_CIGAM_64 = 0xBFBAFECA
MH_MAGIC = 0xFEEDFACE
MH_MAGIC_64 = 0xFEEDFACF
SYSTEM_SWIFT = b"/usr/lib/swift/"
# @rpath Swift overlay dylibs that the modern SDK autolinks but that neither iOS 7
# nor the legacy runtime tree provides.
SYSTEM_SWIFT_NAMES = ("libswiftsimd.dylib", "libswiftUniformTypeIdentifiers.dylib",
                      "libswiftCoreMIDI.dylib", "libswiftCoreLocation.dylib")


def cstr(data, start, size):
    raw = data[start:start + size]
    return raw.split(b"\0", 1)[0]


def slices(data):
    """Yield (offset, size) for each architecture image."""
    if len(data) < 8:
        return None
    magic_be = struct.unpack(">I", data[:4])[0]
    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        endian = ">"
        is64 = magic_be == FAT_MAGIC_64
    elif magic_be in (FAT_CIGAM, FAT_CIGAM_64):
        endian = "<"
        is64 = magic_be == FAT_CIGAM_64
    else:
        return [(0, len(data))]
    count = struct.unpack(endian + "I", data[4:8])[0]
    if count <= 0 or count > 64:
        return None
    entry_size = 32 if is64 else 20
    table = 8
    if table + count * entry_size > len(data):
        return None
    out = []
    for index in range(count):
        base = table + index * entry_size
        if is64:
            _cpu, _sub, offset, size = struct.unpack(endian + "iiQQ", data[base:base + 24])
        else:
            _cpu, _sub, offset, size = struct.unpack(endian + "iiII", data[base:base + 16])
        if offset + size > len(data) or size < 28:
            return None
        out.append((offset, size))
    return out


def patch_slice(data, offset, size):
    le = struct.unpack("<I", data[offset:offset + 4])[0]
    be = struct.unpack(">I", data[offset:offset + 4])[0]
    if le in (MH_MAGIC, MH_MAGIC_64):
        endian = "<"
        is64 = le == MH_MAGIC_64
    elif be in (MH_MAGIC, MH_MAGIC_64):
        endian = ">"
        is64 = be == MH_MAGIC_64
    else:
        return None
    ncmds, sizeofcmds = struct.unpack(endian + "II", data[offset + 16:offset + 24])
    limit = 32 if is64 else 28
    start = offset + limit
    stop = start + sizeofcmds
    if stop > offset + size or ncmds > 4096:
        return None
    stripped = 0
    strong = []
    stripped_names = []
    has_symtab = False
    cursor = start
    for _ in range(ncmds):
        if cursor + 8 > stop:
            return None
        cmd, cmdsize = struct.unpack(endian + "II", data[cursor:cursor + 8])
        if cmdsize < 8 or cursor + cmdsize > stop:
            return None
        if cmd == LC_SYMTAB and cmdsize >= 24:
            if struct.unpack(endian + "I", data[cursor + 12:cursor + 16])[0] > 0:
                has_symtab = True
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
            name_off = struct.unpack(endian + "I", data[cursor + 8:cursor + 12])[0]
            if name_off < cmdsize:
                name = cstr(data, cursor + name_off, cmdsize - name_off)
                wanted = name.startswith(SYSTEM_SWIFT) or (
                    name.startswith(b"@rpath/") and
                    name.rsplit(b"/", 1)[-1].decode() in SYSTEM_SWIFT_NAMES)
                if wanted:
                    if cmd == LC_LOAD_DYLIB:
                        strong.append(name.decode("utf-8", "replace"))
                    else:
                        data[cursor:cursor + 4] = struct.pack(endian + "I", UNUSED_CMD)
                        stripped += 1
                        stripped_names.append(name)
        cursor += cmdsize
    return stripped, strong, stripped_names, has_symtab


FORCE_LOAD_PREFIX = b"__swift_FORCE_LOAD_$_"


def undefined_symbols(path):
    """Undefined symbols of the whole image, or None when they cannot be read."""
    try:
        out = subprocess.run(["/usr/bin/nm", "-u", path], capture_output=True, check=False)
    except OSError:
        return None
    if out.returncode != 0:
        return None
    names = []
    for line in out.stdout.splitlines():
        parts = line.split()
        if parts:
            names.append(parts[-1])
    return names


def referenced(undefined, dylib_name):
    """True when the image references a real symbol from this dylib.

    Only autolink force-load markers are ignored: they exist to make the linker
    load a dylib, not because the code calls into it.
    """
    stem = dylib_name.rsplit(b"/", 1)[-1]
    stem = stem[len(b"libswift"):-len(b".dylib")] if stem.startswith(b"libswift") else stem
    if not stem:
        return False
    needle = stem.lower()
    for name in undefined:
        if name.startswith(FORCE_LOAD_PREFIX):
            continue
        if needle in name.lower():
            return True
    return False


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[-3], file=sys.stderr)
        return 2
    status = 0
    for path in argv[1:]:
        try:
            with open(path, "rb") as handle:
                data = bytearray(handle.read())
        except OSError as error:
            print(f"{path}: {error}", file=sys.stderr)
            status = 2
            continue
        table = slices(bytes(data))
        if table is None:
            print(f"{path}: unsupported Mach-O container", file=sys.stderr)
            status = 2
            continue
        total = 0
        strong_all = []
        stripped_names = []
        has_symtab = False
        for offset, size in table:
            result = patch_slice(data, offset, size)
            if result is None:
                print(f"{path}: malformed load commands", file=sys.stderr)
                status = 2
                continue
            total += result[0]
            stripped_names.extend(result[2])
            strong_all.extend(result[1])
            has_symtab = has_symtab or result[3]
        if strong_all:
            for name in strong_all:
                print(f"{path}: strong system Swift dependency cannot be shipped: {name}", file=sys.stderr)
            status = 1
            continue
        # Symbol verification is on by default. The only way to turn it off is the
        # explicit STRIP_VERIFY_SYMBOLS=0 switch, used by the synthetic unit
        # fixtures; the build pipeline never sets it.
        verify = os.environ.get("STRIP_VERIFY_SYMBOLS", "1") != "0"
        if total and verify:
            if not has_symtab:
                print(f"{path}: no symbol table; refusing to strip blindly", file=sys.stderr)
                status = 1
                continue
            undefined = undefined_symbols(path)
            if undefined is None:
                print(f"{path}: cannot read undefined symbols; refusing to strip blindly", file=sys.stderr)
                status = 1
                continue
            for name in stripped_names:
                if referenced(undefined, name):
                    print(f"{path}: references real symbols from {name.decode(errors='replace')}; "
                          f"stripping the weak load command would leave a dangling reference", file=sys.stderr)
                    status = 1
                    break
            if status:
                continue
        if total:
            with open(path, "wb") as handle:
                handle.write(data)
            print(f"{path}: neutralised {total} weak system Swift load command(s)")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
