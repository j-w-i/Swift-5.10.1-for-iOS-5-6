"""Select the armv7 slice from a Mach-O image.

The legacy runtime started as armv7-only, so the audits below parse a thin little-endian ARM32
image directly. The runtime is now fat (armv7 + armv7s + arm64), and the armv7 slice is still what
those audits must inspect, so fat containers are unwrapped first. Everything else passes through
unchanged, which keeps the audits strict about non-fat inputs they do not understand.
"""
import struct

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
CPU_TYPE_ARM = 12
CPU_SUBTYPE_ARMV7 = 9


def select_armv7(data):
    """Return the armv7 slice of `data`, or `data` unchanged if it is already thin."""
    if len(data) < 8:
        return data
    magic = struct.unpack_from('>I', data, 0)[0]
    if magic not in (FAT_MAGIC, FAT_MAGIC_64):
        return data
    count = struct.unpack_from('>I', data, 4)[0]
    if count == 0 or count > 64:
        raise ValueError('nonsense fat architecture count: %d' % count)
    cursor = 8
    entry_size = 32 if magic == FAT_MAGIC_64 else 20
    fallback = None
    for _ in range(count):
        if cursor + entry_size > len(data):
            raise ValueError('truncated fat architecture table')
        if magic == FAT_MAGIC_64:
            cpu, subtype, offset, size, align, reserved = struct.unpack_from('>iiQQII', data, cursor)
        else:
            cpu, subtype, offset, size, align = struct.unpack_from('>iiIII', data, cursor)
        cursor += entry_size
        if offset + size > len(data) or size == 0:
            raise ValueError('fat slice out of bounds')
        if cpu == CPU_TYPE_ARM:
            if (subtype & 0x00FFFFFF) == CPU_SUBTYPE_ARMV7:
                return data[offset:offset + size]
            if fallback is None:
                fallback = data[offset:offset + size]
    if fallback is not None:
        return fallback
    raise ValueError('fat container has no ARM32 slice')
