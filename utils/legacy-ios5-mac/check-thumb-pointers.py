#!/usr/bin/env python3
"""Reject data pointers into ARM/Thumb code that lack the interworking bit.

The legacy iOS 5 toolchain is linked by an older ld64 that drops the low bit of
local relocations to Thumb functions. The symbol table still marks those
functions as Thumb, so a stored pointer without bit 0 makes iOS 5 dyld enter
Thumb instructions in ARM mode (seen as a trap at function offset 0).

This audits linked images: every absolute data word that resolves to the start
of a Thumb function must carry bit 0. Direct Thumb calls remain allowed; only
address-taken uses are unsafe.

It is a targeted detector for this linker defect, not an exhaustive proof:
symbols must be present (unstripped local text symbols) and ordinary 32-bit words
are scanned in the listed pointer sections only. The pipeline separately
compiles every image it links for iOS 5 in ARM mode, which removes the ambiguity.
"""
import struct
import sys
from pathlib import Path
from armv7slice import select_armv7  # local helper: unwrap fat images to the armv7 slice

N_ARM_THUMB_DEF = 0x0008
# Sections that can hold absolute addresses into __text. Relative-offset Swift
# sections (__swift5_*) are deliberately excluded: their words are offsets, not
# addresses, and can coincidentally equal a text address.
POINTER_SECTIONS = {
    '__const', '__data', '__mod_init_func', '__mod_term_func',
    '__objc_const', '__objc_methlist', '__objc_classlist', '__objc_catlist',
    '__objc_protolist', '__objc_selrefs', '__objc_classrefs',
    '__objc_superrefs', '__cfstring', '__la_symbol_ptr', '__nl_symbol_ptr',
}


def load(path):
    data = select_armv7(Path(path).read_bytes())

    def unpack(fmt, offset):
        size = struct.calcsize(fmt)
        if offset < 0 or offset + size > len(data):
            raise ValueError('truncated Mach-O structure')
        return struct.unpack_from(fmt, data, offset)

    header = unpack('<7I', 0)
    if header[0] != 0xfeedface or header[1] != 12:
        raise ValueError('expected thin little-endian ARM32 Mach-O')
    if header[3] not in (2, 6):
        raise ValueError('expected linked MH_EXECUTE or MH_DYLIB')
    sections = []
    symtab = None
    cursor = 28
    for _ in range(header[4]):
        command, size = unpack('<2I', cursor)
        if size < 8 or cursor + size > 28 + header[5]:
            raise ValueError('invalid load-command size')
        if command == 1:
            segment = unpack('<2I16s8I', cursor)
            if size < 56 + segment[9] * 68:
                raise ValueError('truncated segment section table')
            for index in range(segment[9]):
                raw = unpack('<16s16s9I', cursor + 56 + index * 68)
                sections.append({'name': raw[0].rstrip(b'\0').decode(),
                                 'address': raw[2], 'size': raw[3],
                                 'offset': raw[4], 'flags': raw[8]})
        elif command == 2:
            symtab = unpack('<6I', cursor)[2:]
        cursor += size
    if not symtab:
        raise ValueError('missing symbol table; cannot prove pointer encoding')
    symbol_offset, count, string_offset, string_size = symtab
    if string_offset + string_size > len(data):
        raise ValueError('truncated string table')
    thumb_functions = {}
    instruction_sections = [s for s in sections if s['flags'] & 0x80000400]
    for index in range(count):
        string_index, kind, section, description, value = unpack(
            '<IBBHI', symbol_offset + 12 * index)
        if kind & 0xe0 or kind & 0x0e != 0x0e or section == 0:
            continue
        if not description & N_ARM_THUMB_DEF:
            continue
        if not any(s['address'] <= value < s['address'] + s['size']
                   for s in instruction_sections):
            continue
        if string_index >= string_size:
            raise ValueError('invalid symbol name offset')
        end = data.find(b'\0', string_offset + string_index,
                        string_offset + string_size)
        if end < 0:
            raise ValueError('unterminated symbol name')
        name = data[string_offset + string_index:end].decode(errors='replace')
        thumb_functions.setdefault(value & ~1, []).append(name)
    if not thumb_functions:
        print('PASS: no Thumb code symbols; nothing can lose the bit')
        return
    failures = []
    inspected = 0
    for section in sections:
        if section['name'] not in POINTER_SECTIONS or section['size'] < 4:
            continue
        if section['offset'] + section['size'] > len(data):
            raise ValueError('truncated pointer section')
        # Scan every complete 32-bit word; sections are commonly padded/mixed, so
        # a non-multiple-of-four size must not hide all preceding pointers.
        for offset in range(0, section['size'] - 3, 4):
            word, = unpack('<I', section['offset'] + offset)
            inspected += 1
            if word & 1 or word not in thumb_functions:
                continue
            failures.append('0x%08x in __DATA,%s -> %s' %
                            (word, section['name'],
                             ', '.join(thumb_functions[word][:3])))
    if failures:
        raise ValueError('%d pointer(s) enter Thumb code without bit 0:\n  %s'
                         % (len(failures), '\n  '.join(failures[:10])))
    print('PASS: %d pointer words; every Thumb-code pointer carries the '
          'interworking bit (%d Thumb functions present)' % (inspected, len(thumb_functions)))


def self_test():
    """Build two minimal synthetic MH_DYLIB images and assert the audit verdict."""
    def image(pointer):
        text_address, text_offset = 0x1000, 0x400
        const_address = 0x2000
        nsyms = 1
        symtab_size = 24
        segment_size = 56 + 2 * 68
        sizeofcmds = 2 * 72 + segment_size + symtab_size
        total = const_address + 4
        data = bytearray(total)
        struct.pack_into('<7I', data, 0, 0xfeedface, 12, 6, 6, 2, sizeofcmds, 0)
        struct.pack_into('<2I', data, 28, 1, segment_size)
        struct.pack_into('<2I16s8I', data, 28, 1, segment_size, b'\0' * 16,
                         0, total, 0, total, 7, 5, 2, 0)
        # __text (instructions) then __DATA,__const (pointer word)
        struct.pack_into('<16s16s9I', data, 28 + 56, b'__text', b'__TEXT',
                         text_address, 4, text_offset, 2, 0, 0,
                         0x80000400, 0, 0)
        struct.pack_into('<16s16s9I', data, 28 + 56 + 68, b'__const', b'__DATA',
                         const_address, 4, const_address, 2, 0, 0, 0, 0, 0)
        command = 28 + 56 + 2 * 68
        struct.pack_into('<2I', data, command, 2, symtab_size)
        struct.pack_into('<6I', data, command, 2, symtab_size, 0x300, 1, 0x340, 16)
        # One Thumb function symbol in __text, value with N_ARM_THUMB_DEF.
        struct.pack_into('<IBBHI', data, 0x300, 1, 0x0e, 1, 0x0008, text_address)
        data[0x340:0x342] = b'\0f'
        if pointer is not None:
            struct.pack_into('<I', data, const_address, pointer)
        return bytes(data)

    good = image(0x1001)   # Thumb pointer carrying bit 0
    bad = image(0x1000)    # same function, bit lost
    for label, payload, should_pass in (('thumb-bit pointer', good, True),
                                        ('lost-bit pointer', bad, False)):
        path = Path('/tmp/thumb-audit-self-test-%d' % should_pass)
        path.write_bytes(payload)
        try:
            load(path)
            failure = None
        except ValueError as error:
            failure = error
        finally:
            path.unlink()
        if should_pass and failure:
            raise ValueError('self-test expected pass but failed: ' + str(failure))
        if not should_pass and not failure:
            raise ValueError('self-test expected failure but passed: ' + label)
    print('PASS: thumb-pointer audit self-tests')


if __name__ == '__main__':
    if len(sys.argv) == 2 and sys.argv[1] == '--self-test':
        try:
            self_test()
        except (ValueError, OSError, struct.error) as error:
            raise SystemExit('FAIL: ' + str(error))
        raise SystemExit(0)
    try:
        load(sys.argv[1])
    except (ValueError, IndexError, OSError, struct.error) as error:
        raise SystemExit('FAIL: ' + str(error))
