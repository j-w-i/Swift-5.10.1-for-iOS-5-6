"""Read-only, bounds-checked selection of ARM32 slices for iOS qualification."""
import struct

ARM_SUBTYPES = {'armv7': 9, 'armv7s': 11}
FAT_FORMATS = {
    b'\xca\xfe\xba\xbe': ('>', False),
    b'\xbe\xba\xfe\xca': ('<', False),
    b'\xca\xfe\xba\xbf': ('>', True),
    b'\xbf\xba\xfe\xca': ('<', True),
}


def arm32_slice(data, arch='armv7'):
    """Select exactly arch, never fall back to another CPU/subtype.

    Returned bytes use slice-relative Mach-O file offsets. Validate every fat
    entry's extent before selecting, so an invalid/overlapping container cannot
    make an audit consume another slice or the universal header as payload.
    """
    if arch not in ARM_SUBTYPES:
        raise ValueError('unsupported ARM32 audit architecture: ' + arch)
    expected = ARM_SUBTYPES[arch]

    def unpack(fmt, offset):
        size = struct.calcsize(fmt)
        if offset < 0 or offset + size > len(data):
            raise ValueError('truncated Mach-O slice table/header')
        return struct.unpack_from(fmt, data, offset)

    fat = FAT_FORMATS.get(data[:4])
    if fat:
        endian, wide = fat
        count, = unpack(endian + 'I', 4)
        entry_size = 32 if wide else 20
        table_end = 8 + count * entry_size
        if not count or table_end > len(data):
            raise ValueError('empty or truncated fat architecture table')
        entries, identities = [], set()
        for index in range(count):
            entry = unpack(endian + ('IIQQII' if wide else 'IIIII'),
                           8 + index * entry_size)
            cpu, subtype, offset, size, alignment = entry[:5]
            identity = (cpu, subtype & 0x00ffffff)
            if identity in identities:
                raise ValueError('duplicate fat architecture')
            identities.add(identity)
            if wide and entry[5]:
                raise ValueError('nonzero fat64 reserved field')
            if (not size or offset < table_end or offset + size > len(data)
                    or alignment > 63 or offset % (1 << alignment)):
                raise ValueError('invalid fat slice range/alignment')
            entries.append((offset, size, cpu, subtype))
        ordered = sorted(entries)
        for previous, current in zip(ordered, ordered[1:]):
            if previous[0] + previous[1] > current[0]:
                raise ValueError('overlapping fat slices')
        matches = [entry for entry in entries
                   if entry[2] == 12 and entry[3] & 0x00ffffff == expected]
        if len(matches) != 1:
            raise ValueError('missing requested ' + arch + ' slice')
        offset, size, cpu, subtype = matches[0]
        selected = data[offset:offset + size]
        if len(selected) < 28:
            raise ValueError('truncated selected Mach-O header')
        magic, actual_cpu, actual_subtype = struct.unpack_from('<3I', selected)
        if actual_cpu != cpu or actual_subtype != subtype:
            raise ValueError('fat architecture does not match Mach-O header')
    else:
        selected = data
        magic, actual_cpu, actual_subtype = unpack('<3I', 0)
    if magic != 0xfeedface or actual_cpu != 12:
        raise ValueError('expected little-endian ARM32 Mach-O for ' + arch)
    if actual_subtype & 0x00ffffff != expected:
        raise ValueError('Mach-O CPU subtype is not requested ' + arch)
    return selected
