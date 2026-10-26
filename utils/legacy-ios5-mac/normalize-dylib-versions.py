#!/usr/bin/env python3
"""Normalize Mach-O dylib version stamps in a directory of Swift runtime libraries.

The from-source overlays are linked by tools whose default LC_ID_DYLIB version is
0.0.0, while the runtime's own dylibs were linked expecting compatibility version
1.0.0. iOS 5's dyld (199.6) enforces that check and aborts the app with

    Library not loaded: @rpath/libswiftDispatch.dylib
    Reason: Incompatible library version: libswiftos.dylib requires version 1.0.0
            or later, but libswiftDispatch.dylib provides version 0.0.0

This script raises every packaged dylib's compatibility (and, when lower, current)
version to at least the highest compatibility version any packaged library requires
of it, and never below 1.0.0. Only the two 32-bit version fields of LC_ID_DYLIB are
rewritten; nothing else in the image changes, so all other load commands, symbols
and code signatures of the *other* files stay byte-identical.

Usage: normalize-dylib-versions.py <directory> [--dry-run]
"""
import struct
import sys
from pathlib import Path

MH_MAGIC = 0xFEEDFACE
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
LC_ID_DYLIB = 0x0D
LOAD_DYLIB_COMMANDS = {0x0C, 0x18, 0x1F, 0x20, 0x8000001F}  # LOAD, LOAD_WEAK, REEXPORT, LAZY, LOAD_UPWARD
MIN_VERSION = (1, 0, 0)


def pack(version):
    return (version[0] << 16) | (version[1] << 8) | version[2]


def unpack(value):
    return ((value >> 16) & 0xFFFF, (value >> 8) & 0xFF, value & 0xFF)


def slices(data):
    """Yield (offset, size) for each thin Mach-O image inside data."""
    magic_le = struct.unpack_from("<I", data, 0)[0]
    magic_be = struct.unpack_from(">I", data, 0)[0]
    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        count = struct.unpack_from(">I", data, 4)[0]
        base = 8
        entry_size = 20 if magic_be == FAT_MAGIC else 32
        for index in range(count):
            offset = struct.unpack_from(">I", data, base + index * entry_size + 8)[0]
            size = struct.unpack_from(">I", data, base + index * entry_size + 12)[0]
            yield offset, size
        return
    if magic_le in (MH_MAGIC, MH_MAGIC_64):
        yield 0, len(data)
        return
    raise ValueError("not a Mach-O file")


def commands(data, offset):
    magic = struct.unpack_from("<I", data, offset)[0]
    is64 = magic == MH_MAGIC_64
    header = 32 if is64 else 28
    ncmds = struct.unpack_from("<I", data, offset + 16)[0]
    cursor = offset + header
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, cursor)
        yield cursor, cmd, cmdsize
        cursor += cmdsize


def id_version_fields(data, offset):
    for cursor, cmd, _ in commands(data, offset):
        if cmd == LC_ID_DYLIB:
            current = struct.unpack_from("<I", data, cursor + 16)[0]
            compatible = struct.unpack_from("<I", data, cursor + 20)[0]
            return cursor + 16, current, compatible
    return None


def required_versions(data):
    """Map dylib basename -> highest compatibility version required of it."""
    required = {}
    for offset, _ in slices(data):
        for cursor, cmd, cmdsize in commands(data, offset):
            if cmd not in LOAD_DYLIB_COMMANDS:
                continue
            name_offset = struct.unpack_from("<I", data, cursor + 8)[0]
            start = cursor + name_offset
            end = data.find(b"\x00", start, cursor + cmdsize)
            name = data[start:end].decode("utf-8", "replace")
            version = unpack(struct.unpack_from("<I", data, cursor + 20)[0])
            base = name.rsplit("/", 1)[-1]
            if version > required.get(base, (0, 0, 0)):
                required[base] = version
    return required


def main(argv):
    if not argv:
        print(__doc__, file=sys.stderr)
        return 64
    directory = Path(argv[0])
    dry_run = "--dry-run" in argv
    libraries = sorted(directory.glob("*.dylib"))
    if not libraries:
        print("no dylibs in " + str(directory), file=sys.stderr)
        return 1

    required = {}
    for library in libraries:
        for name, version in required_versions(library.read_bytes()).items():
            if version > required.get(name, (0, 0, 0)):
                required[name] = version

    changed = 0
    for library in libraries:
        data = bytearray(library.read_bytes())
        target = max(required.get(library.name, (0, 0, 0)), MIN_VERSION)
        updated = False
        for offset, _ in slices(data):
            fields = id_version_fields(data, offset)
            if fields is None:
                continue
            current_at, current, compatible = fields
            new_compatible = max(unpack(compatible), target)
            new_current = max(unpack(current), new_compatible)
            if unpack(compatible) != new_compatible or unpack(current) != new_current:
                struct.pack_into("<I", data, current_at, pack(new_current))
                struct.pack_into("<I", data, current_at + 4, pack(new_compatible))
                updated = True
                print("%-28s %s -> %s" % (library.name, ".".join(map(str, unpack(compatible))),
                                          ".".join(map(str, new_compatible))))
        if updated:
            changed += 1
            if not dry_run:
                library.write_bytes(bytes(data))
    print("normalized %d of %d dylib version stamps%s" %
          (changed, len(libraries), " (dry run)" if dry_run else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
