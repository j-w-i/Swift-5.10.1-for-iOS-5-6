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

LC_VERSION_MIN_IPHONEOS = 0x25
LC_BUILD_VERSION = 0x32
MH_EXECUTE = 2
LC_REEXPORT_DYLIB = 0x8000001F
LC_RPATH = 0x8000001C
LC_SYMTAB = 0x2
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
UNUSED_CMD = 0x1F01
UNAVAILABLE = b"/.unavailable"


def unavailable_at(index):
    """The index-th unusable path: /.unavailable, /.unavailable2, /.unavailable3, ..."""
    return UNAVAILABLE if index == 0 else UNAVAILABLE + str(index + 1).encode()


FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
FAT_MAGIC_64 = 0xCAFEBABF
FAT_CIGAM_64 = 0xBFBAFECA
MH_MAGIC = 0xFEEDFACE
MH_MAGIC_64 = 0xFEEDFACF
SWIFT_CORE = b"@rpath/libswiftCore.dylib"
SYSTEM_SWIFT = b"/usr/lib/swift/"
SYSTEM_SWIFT_RPATH = b"/usr/lib/swift"
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


def fresh_unavailable(taken):
    """The first unusable path not in `taken`.

    Every neutralised entry needs a path of its own: dyld on current iOS aborts a launch whose
    image lists the same LC_RPATH twice ("duplicate LC_RPATH"), and likewise the same weak dylib
    path twice (observed on iOS 27 with libswiftQuickLook and libswiftsimd both neutralised).
    """
    index = 0
    while unavailable_at(index) in taken:
        index += 1
    return unavailable_at(index)


def repoint(data, cursor, cmdsize, path_off, replacement):
    """Overwrite a load command's path in place. False when the old path's space is too small."""
    room = cmdsize - path_off
    if room <= len(replacement):
        return False
    data[cursor + path_off:cursor + cmdsize] = b"\0" * room
    data[cursor + path_off:cursor + path_off + len(replacement)] = replacement
    return True


def command_path(data, cursor, cmd, cmdsize, endian):
    """(offset, path) of an LC_RPATH or dylib load command's path, or None."""
    if cmd == LC_RPATH and cmdsize >= 12:
        path_off = struct.unpack(endian + "I", data[cursor + 8:cursor + 12])[0]
    elif cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB) and cmdsize >= 24:
        path_off = struct.unpack(endian + "I", data[cursor + 8:cursor + 12])[0]
    else:
        return None
    if path_off >= cmdsize:
        return None
    return path_off, bytes(cstr(data, cursor + path_off, cmdsize - path_off))


def patch_slice(data, offset, size, reexport_core=False, drop_system_rpath=False, linked_sdk=None):
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
    filetype = struct.unpack(endian + "I", data[offset + 12:offset + 16])[0]
    ncmds, sizeofcmds = struct.unpack(endian + "II", data[offset + 16:offset + 24])
    limit = 32 if is64 else 28
    start = offset + limit
    stop = start + sizeofcmds
    if stop > offset + size or ncmds > 4096:
        return None
    # Unusable paths already in the image (from an earlier run of this tool). New ones avoid all
    # of them, so a path handed out here never collides with an entry further down.
    taken = set()
    cursor = start
    for _ in range(ncmds):
        if cursor + 8 > stop:
            return None
        cmd, cmdsize = struct.unpack(endian + "II", data[cursor:cursor + 8])
        if cmdsize < 8 or cursor + cmdsize > stop:
            return None
        found = command_path(data, cursor, cmd, cmdsize, endian)
        if found and found[1].startswith(UNAVAILABLE):
            taken.add(found[1])
        cursor += cmdsize
    claimed = set()

    def neutralise(cursor, cmdsize, path_off):
        replacement = fresh_unavailable(taken)
        if not repoint(data, cursor, cmdsize, path_off, replacement):
            return False
        taken.add(replacement)
        claimed.add(replacement)
        return True

    stripped = 0
    strong = []
    stripped_names = []
    has_symtab = False
    reexported = 0
    dropped_rpaths = 0
    seen_rpaths = set()
    sdk_retagged = 0
    deduplicated = 0
    cursor = start
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack(endian + "II", data[cursor:cursor + 8])
        found = command_path(data, cursor, cmd, cmdsize, endian)
        # An entry an earlier run of this tool neutralised. Older versions gave every weak dylib
        # the same path, which dyld on current iOS rejects, so a repeat gets a path of its own.
        if found and found[1].startswith(UNAVAILABLE):
            if found[1] in claimed:
                if neutralise(cursor, cmdsize, found[0]):
                    deduplicated += 1
            else:
                claimed.add(found[1])
            cursor += cmdsize
            continue
        # Apple's overlay stubs declare libswiftCore as a *re-export*. A shipped
        # overlay that merely loads Core makes dyld's two-level lookup fail for
        # symbols the linker attributed to the overlay (observed on iOS 27 as
        # "Symbol not found: _$s15_ObjectiveCTypes01_A11CBridgeablePTl").
        if reexport_core and filetype == 6 and cmd == LC_LOAD_DYLIB and found:
            if found[1] == SWIFT_CORE:
                data[cursor:cursor + 4] = struct.pack(endian + "I", LC_REEXPORT_DYLIB)
                reexported += 1
        if cmd == LC_RPATH and found:
            path_off, path = found
            # dyld on current iOS aborts a launch whose image lists the same LC_RPATH twice
            # ("duplicate LC_RPATH"). Both the driver and the project's runpath setting add
            # @executable_path/Frameworks, so repoint every repeat at an unusable path.
            if path in seen_rpaths:
                if neutralise(cursor, cmdsize, path_off):
                    dropped_rpaths += 1
            else:
                seen_rpaths.add(path)
                # The Swift driver emits `-rpath /usr/lib/swift`. On iOS 12+ that path holds
                # the system Swift runtime, which shadows the stdlib embedded in this app and
                # breaks five-year-old ABI (observed on iOS 27: protocol descriptor missing).
                # Neutralise the entry so @rpath resolves only to the app's Frameworks.
                if drop_system_rpath and path == SYSTEM_SWIFT_RPATH:
                    # Keep a *valid* LC_RPATH (pointing nowhere) rather than retyping the command:
                    # a retyped command makes install_name_tool/lipo-style tools reject the image.
                    if not neutralise(cursor, cmdsize, path_off):
                        data[cursor:cursor + 4] = struct.pack(endian + "I", UNUSED_CMD)
                    dropped_rpaths += 1
        # UIKit chooses between its compatibility layout and the current one from the SDK the
        # main executable was *linked* against. Source written for modern iOS (safe areas, bar
        # metrics) expects the current layout, which an app linked against an old SDK never gets
        # on a new system. EVERY executable slice is retagged, not just the 64-bit one: measured
        # on an iPhone 15 Pro (iOS 27), a fat armv7+arm64 executable whose armv7 slice still said
        # SDK 15.5 laid out 390x844 (zoomed compatibility size) even though the arm64 slice said
        # 19.0; tagging both gave the native 393x852. The tag is advisory metadata on older
        # systems (iOS 5 dyld ignores the SDK field; verified on iOS 5.1.1 and 10.3.3 devices).
        if (linked_sdk is not None and filetype == MH_EXECUTE and
                cmd in (LC_VERSION_MIN_IPHONEOS, LC_BUILD_VERSION)):
            sdk_off = cursor + (12 if cmd == LC_VERSION_MIN_IPHONEOS else 16)
            current = struct.unpack(endian + "I", data[sdk_off:sdk_off + 4])[0]
            if current < linked_sdk:
                data[sdk_off:sdk_off + 4] = struct.pack(endian + "I", linked_sdk)
                sdk_retagged += 1
        if cmd == LC_SYMTAB and cmdsize >= 24:
            if struct.unpack(endian + "I", data[cursor + 12:cursor + 16])[0] > 0:
                has_symtab = True
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB) and found:
            path_off, name = found
            wanted = name.startswith(SYSTEM_SWIFT) or (
                name.startswith(b"@rpath/") and
                name.rsplit(b"/", 1)[-1].decode() in SYSTEM_SWIFT_NAMES)
            if wanted:
                if cmd == LC_LOAD_DYLIB:
                    strong.append(name.decode("utf-8", "replace"))
                else:
                    # Keep the command a *weak* dylib so its two-level-namespace ordinal slot
                    # survives (retyping it removed the slot, and binds past the end of the list
                    # make dyld reject the image: "library ordinal (28) too big (max 27)" on
                    # iOS 10). Pointing it at a path that cannot exist makes the weak load a no-op
                    # on every OS, including those that ship the real system overlay. Each entry
                    # gets its own path (see fresh_unavailable).
                    if not neutralise(cursor, cmdsize, path_off):
                        data[cursor:cursor + 4] = struct.pack(endian + "I", UNUSED_CMD)
                    stripped += 1
                    stripped_names.append(name)
        cursor += cmdsize
    return (stripped, strong, stripped_names, has_symtab, reexported, dropped_rpaths, sdk_retagged,
            deduplicated)


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
    if len(argv) < 2 or not any(not a.startswith("-") for a in argv[1:]):
        print("Usage: strip-system-swift-deps.py [--reexport-core] [--drop-system-swift-rpath] [--linked-sdk=N.M] IMAGE [IMAGE...]", file=sys.stderr)
        return 2
    status = 0
    reexport_core = False
    drop_rpath = False
    linked_sdk = None
    paths = []
    for argument in argv[1:]:
        if argument == "--reexport-core":
            reexport_core = True
        elif argument == "--drop-system-swift-rpath":
            drop_rpath = True
        elif argument.startswith("--linked-sdk="):
            major, _, minor = argument.split("=", 1)[1].partition(".")
            linked_sdk = (int(major) << 16) | (int(minor or 0) << 8)
        else:
            paths.append(argument)
    for path in paths:
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
        reexported = 0
        dropped_rpaths = 0
        retagged = 0
        deduplicated = 0
        for offset, size in table:
            result = patch_slice(data, offset, size, reexport_core=reexport_core, drop_system_rpath=drop_rpath, linked_sdk=linked_sdk)
            if result is None:
                print(f"{path}: malformed load commands", file=sys.stderr)
                status = 2
                continue
            total += result[0]
            stripped_names.extend(result[2])
            strong_all.extend(result[1])
            has_symtab = has_symtab or result[3]
            reexported += result[4]
            dropped_rpaths += result[5]
            retagged += result[6]
            deduplicated += result[7]
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
        if total or reexported or dropped_rpaths or retagged or deduplicated:
            with open(path, "wb") as handle:
                handle.write(data)
            if total:
                print(f"{path}: neutralised {total} weak system Swift load command(s)")
            if reexported:
                print(f"{path}: made libswiftCore a re-export ({reexported} slice(s))")
            if dropped_rpaths:
                print(f"{path}: dropped /usr/lib/swift from the rpath search order ({dropped_rpaths} slice(s))")
            if retagged:
                print(f"{path}: linked-SDK tag raised for {retagged} executable slice(s)")
            if deduplicated:
                print(f"{path}: gave {deduplicated} repeated neutralised path(s) a distinct one")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
