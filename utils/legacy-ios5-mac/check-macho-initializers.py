#!/usr/bin/env python3
"""Audit unstripped, PST-containing armv7 dylib constructor instruction state.

Usage: check-macho-initializers.py [--generic] DYLIB | --self-test
Checks all S_MOD_INIT_FUNC_POINTERS entries. By default also requires both PST
constructors; --generic audits other dylibs without the UIKit-specific names.
Read-only: no Mach-O rewriting, external tools, or installed-output changes.
"""
import struct
import sys
from pathlib import Path

def audit(path, require_pst=True):
    audit_bytes(Path(path).read_bytes(), require_pst=require_pst)


def audit_bytes(data, require_pst=True):
    def unpack(fmt, offset):
        size = struct.calcsize(fmt)
        if offset < 0 or offset + size > len(data):
            raise ValueError('truncated Mach-O structure')
        return struct.unpack_from(fmt, data, offset)
    header = unpack('<7I', 0)
    if header[0] != 0xfeedface or header[1] != 12:
        raise ValueError('expected thin little-endian ARM32 Mach-O')
    if header[3] != 6:
        raise ValueError('expected linked MH_DYLIB, not relocatable objects')
    cursor = 28
    sections = []
    symtab = None
    for _ in range(header[4]):
        command, size = unpack('<2I', cursor)
        if size < 8 or cursor + size > 28 + header[5]:
            raise ValueError('invalid load-command size')
        if command == 1:  # LC_SEGMENT (32-bit)
            segment = unpack('<2I16s8I', cursor)
            if size < 56 + segment[9] * 68:
                raise ValueError('truncated segment section table')
            for index in range(segment[9]):
                section = unpack('<16s16s9I', cursor + 56 + index * 68)
                sections.append({'name': section[0].rstrip(b'\0').decode(),
                                 'address': section[2], 'size': section[3],
                                 'offset': section[4], 'flags': section[8]})
        elif command == 2:  # LC_SYMTAB
            symtab = unpack('<6I', cursor)[2:]
        cursor += size
    if not symtab:
        raise ValueError('missing symbol table; cannot prove instruction state')
    symbol_offset, count, string_offset, string_size = symtab
    if string_offset + string_size > len(data):
        raise ValueError('truncated string table')
    symbols = {}
    for index in range(count):
        string_index, kind, section, description, value = unpack('<IBBHI', symbol_offset + 12 * index)
        if kind & 0xe0 or kind & 0x0e != 0x0e or section == 0:
            continue
        if string_index >= string_size:
            raise ValueError('invalid symbol name offset')
        end = data.find(b'\0', string_offset + string_index, string_offset + string_size)
        if end < 0:
            raise ValueError('unterminated symbol name')
        name = data[string_offset + string_index:end].decode(errors='replace')
        symbols.setdefault(value & ~1, []).append((name, bool(description & 0x0008), section))
    checked = []
    for section in sections:
        if section['flags'] & 0xff != 9:  # S_MOD_INIT_FUNC_POINTERS
            continue
        if section['size'] % 4:
            raise ValueError('misaligned initializer pointer section')
        for offset in range(0, section['size'], 4):
            pointer, = unpack('<I', section['offset'] + offset)
            address = pointer & ~1
            targets = symbols.get(address, [])
            # Restrict to symbols in executable/instruction sections. Multiple
            # same-address aliases must agree on ARM vs Thumb instruction state.
            targets = [(name, thumb) for name, thumb, ordinal in targets
                       if name and ordinal <= len(sections)
                       and sections[ordinal - 1]['flags'] & 0x80000400
                       and sections[ordinal - 1]['address'] <= address
                       < sections[ordinal - 1]['address'] + sections[ordinal - 1]['size']]
            if not pointer or not targets:
                raise ValueError('initializer 0x%x lacks a defined code symbol' % pointer)
            states = {thumb for _, thumb in targets}
            if states != {bool(pointer & 1)}:
                raise ValueError('initializer 0x%x instruction-state mismatch: %r' % (pointer, targets))
            if not pointer & 1 and address % 4:
                raise ValueError('ARM initializer 0x%x is not four-byte aligned' % pointer)
            checked.extend(name for name, _ in targets)
            print('initializer 0x%08x: %s (%s)' %
                  (pointer, ', '.join(name for name, _ in targets), 'Thumb' if pointer & 1 else 'ARM'))
    for required in (('PSTInstallIndexPathAdditions', 'PSTCreateUICollectionViewClasses') if require_pst else ()):
        if not any(name.endswith(required) for name in checked):
            raise ValueError('missing audited PST constructor: ' + required)
    print('PASS: linked initializer pointers agree with ARM/Thumb symbol state')

def self_test():
    # Entirely synthetic in-memory Mach-O fixtures: never modify linked binaries.
    import contextlib
    import io

    def fixture(pointers, descriptions, addresses=(0x1000, 0x1004)):
        segment_size = 56 + 2 * 68
        commands_size = segment_size + 24
        code_offset = 28 + commands_size
        init_offset = code_offset + 8
        symbols_offset = init_offset + 8
        strings_offset = symbols_offset + 24
        names = b'\0_PSTInstallIndexPathAdditions\0_PSTCreateUICollectionViewClasses\0'
        header = struct.pack('<7I', 0xfeedface, 12, 9, 6, 2, commands_size, 0)
        segment = struct.pack('<2I16s8I', 1, segment_size, b'__TEXT',
                              0x1000, 0x2000, 0, strings_offset + len(names), 7, 7, 2, 0)
        section = lambda name, address, size, offset, flags: struct.pack(
            '<16s16s9I', name, b'__TEXT', address, size, offset, 2, 0, 0, flags, 0, 0)
        code = section(b'__text', 0x1000, 8, code_offset, 0x80000400)
        initializers = section(b'__mod_init_func', 0x2000, 8, init_offset, 9)
        symtab = struct.pack('<6I', 2, 24, symbols_offset, 2, strings_offset, len(names))
        symbols = b''.join(struct.pack('<IBBHI', index, 0x0e, 1, desc, address)
                           for index, desc, address in zip((1, names.index(b'_PSTCreate')), descriptions, addresses))
        return header + segment + code + initializers + symtab + b'\0' * 8 + struct.pack('<2I', *pointers) + symbols + names

    cases = (
        ('ARM pointers', fixture((0x1000, 0x1004), (0, 0)), None),
        ('Thumb pointers', fixture((0x1001, 0x1005), (8, 8)), None),
        ('missing Thumb bit', fixture((0x1000, 0x1004), (8, 8)), 'instruction-state mismatch'),
        ('spurious Thumb bit', fixture((0x1001, 0x1005), (0, 0)), 'instruction-state mismatch'),
        ('misaligned ARM', fixture((0x1002, 0x1004), (0, 0), (0x1002, 0x1004)), 'four-byte aligned'),
        ('null pointer', fixture((0, 0x1004), (0, 0)), 'lacks a defined code symbol'),
        ('unmapped pointer', fixture((0x3000, 0x1004), (0, 0)), 'lacks a defined code symbol'),
        ('truncated image', b'\xce\xfa\xed\xfe', 'truncated'),
    )
    def without_pst_names(data):
        for name in (b'PSTInstallIndexPathAdditions', b'PSTCreateUICollectionViewClasses'):
            data = data.replace(name, b'X' * len(name))
        return data
    generic = without_pst_names(fixture((0x1000, 0x1004), (0, 0)))
    unsafe_generic = without_pst_names(fixture((0x1000, 0x1004), (8, 8)))
    cases = tuple((name, data, expected, True) for name, data, expected in cases) + (
        ('generic constructors', generic, None, False),
        ('PST requirement retained', generic, 'missing audited PST constructor', True),
        ('generic instruction mismatch', unsafe_generic, 'instruction-state mismatch', False),
    )
    for name, data, expected, require_pst in cases:
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                audit_bytes(data, require_pst=require_pst)
        except ValueError as error:
            if expected is None or expected not in str(error):
                raise ValueError('self-test %s: unexpected rejection: %s' % (name, error))
        else:
            if expected is not None:
                raise ValueError('self-test %s: accepted unsafe image' % name)
    print('PASS: initializer audit self-tests (%d fixtures)' % len(cases))


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['--self-test']:
            self_test()
        elif len(sys.argv) == 3 and sys.argv[1] == '--generic':
            audit(sys.argv[2], require_pst=False)
        elif len(sys.argv) == 2:
            audit(sys.argv[1])
        else:
            raise ValueError('usage: check-macho-initializers.py [--generic] DYLIB | --self-test')
    except (ValueError, IndexError, OSError, struct.error) as error:
        raise SystemExit('FAIL: ' + str(error))
