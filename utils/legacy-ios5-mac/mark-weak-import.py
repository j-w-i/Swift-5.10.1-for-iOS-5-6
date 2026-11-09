#!/usr/bin/env python3
"""Mark named undefined symbols in a Mach-O image as weak imports.

Why this exists
---------------
The armv7 media overlays (CoreAudio/CoreMedia/AVFoundation) are linked at the iOS 5.0 floor with the
modern toolchain. Its libc++ stub records `_voucher_adopt` (a libSystem export that first appears on
iOS 12) as a strong import, even though the overlay objects never reference it: it is reachable only
from libc++ paths the overlays never execute. iOS 5.1.1 has no such export, so an embedded runtime that
strongly imports it would be rejected by the iOS 5 qualification gate.

The symbols are turned into weak imports instead of suppressing undefined symbols, so dyld still binds
them where they exist and nothing is hidden from the loader.

Usage: mark-weak-import.py IMAGE SYMBOL [SYMBOL...]
Exit: 0 changed or nothing to do; 1 no symbol table; 2 malformed input.
"""
import struct
import sys

N_WEAK_REF = 0x0040
MH_MAGIC, MH_MAGIC_64 = 0xFEEDFACE, 0xFEEDFACF
FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64 = 0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA
LC_SYMTAB = 0x2


def slices(data):
    if len(data) < 8:
        return None
    be = struct.unpack(">I", data[:4])[0]
    if be == FAT_MAGIC:
        count = struct.unpack(">I", data[4:8])[0]
        return [(struct.unpack(">I", data[8 + 20 * i + 8:8 + 20 * i + 12])[0],
                 struct.unpack(">I", data[8 + 20 * i + 12:8 + 20 * i + 16])[0]) for i in range(count)]
    return [(0, len(data))]


def patch(data, offset, size, wanted):
    magic = struct.unpack("<I", data[offset:offset + 4])[0]
    if magic == MH_MAGIC_64:
        is64, header = True, 32
    elif magic == MH_MAGIC:
        is64, header = False, 28
    else:
        return None
    ncmds = struct.unpack("<I", data[offset + 16:offset + 20])[0]
    cursor = offset + header
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", data[cursor:cursor + 8])
        if cmd == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack("<IIII", data[cursor + 8:cursor + 24])
            entry = 16 if is64 else 12
            changed = 0
            for index in range(nsyms):
                start = offset + symoff + index * entry
                strx, ntype, nsect, ndesc, nvalue = struct.unpack("<IBBH", data[start:start + 8]) + (
                    struct.unpack("<Q", data[start + 8:start + 16])[0] if is64 else
                    struct.unpack("<I", data[start + 8:start + 12])[0],)
                if ntype & 0x0E != 0:  # N_UNDF
                    continue
                if ntype & 0x01:       # N_EXT
                    pass
                else:
                    continue
                if ntype & 0x0E:
                    continue
                name_start = offset + stroff + strx
                raw = data[name_start:offset + stroff + strsize].split(b"\0", 1)[0]
                if raw.decode("utf-8", "replace") in wanted:
                    if not ndesc & N_WEAK_REF:
                        data[start + 6:start + 8] = struct.pack("<H", ndesc | N_WEAK_REF)
                        changed += 1
            return changed
        cursor += cmdsize
    return None


def main(argv):
    if len(argv) < 3:
        print("usage: mark-weak-import.py IMAGE SYMBOL [SYMBOL...]", file=sys.stderr)
        return 2
    path, wanted = argv[1], set(argv[2:])
    try:
        with open(path, "rb") as handle:
            data = bytearray(handle.read())
    except OSError as error:
        print(f"{path}: {error}", file=sys.stderr)
        return 2
    table = slices(bytes(data))
    total = 0
    for offset, size in table:
        result = patch(data, offset, size, wanted)
        if result is None:
            print(f"{path}: no symbol table", file=sys.stderr)
            return 1
        total += result
    if total:
        with open(path, "wb") as handle:
            handle.write(data)
        print(f"{path}: {total} import(s) marked weak")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
