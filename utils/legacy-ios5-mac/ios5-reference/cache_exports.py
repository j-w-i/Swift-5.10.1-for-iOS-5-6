#!/usr/bin/env python3
"""Export database for an iOS 5-era dyld_v1 shared cache.

Usage: cache_exports.py CACHE OUT.json
Writes {image_path: [exported_symbol, ...]} by reading each in-cache Mach-O's
LC_SYMTAB (external, defined symbols) with cache addresses mapped to file offsets.
"""
import json, struct, sys
data = open(sys.argv[1], 'rb').read()
magic, mo, mc, io, ic, base = struct.unpack_from('<16s5I', data, 0)
maps = [struct.unpack_from('<QQQII', data, mo + i * 32) for i in range(mc)]
def a2o(a):
    for addr, size, off, _, _ in maps:
        if addr <= a < addr + size: return off + a - addr
    return None
out = {}
for i in range(ic):
    addr, _, _, pathoff, _ = struct.unpack_from('<QQQII', data, io + i * 32)
    end = data.index(b'\0', pathoff); path = data[pathoff:end].decode()
    o = a2o(addr)
    if o is None or struct.unpack_from('<I', data, o)[0] != 0xFEEDFACE: continue
    ncmds = struct.unpack_from('<I', data, o + 16)[0]; c = o + 28; syms = []
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from('<2I', data, c)
        if cmd == 2:
            symoff, nsyms, stroff, strsize = struct.unpack_from('<4I', data, c + 8)
            for k in range(nsyms):
                si, t, s, desc, v = struct.unpack_from('<IBBHI', data, symoff + 12 * k)
                if t & 0x0e == 0x0e and t & 1 and s != 0:
                    e = data.index(b'\0', stroff + si)
                    syms.append(data[stroff + si:e].decode(errors='replace'))
        c += sz
    out[path] = syms
json.dump(out, open(sys.argv[2], 'w'))
print(len(out), 'images,', sum(len(v) for v in out.values()), 'exported symbols')
