#!/usr/bin/env python3
"""Decrypt an Apple 'encrcdsa' v2 DMG (iOS 5 rootfs) given the published 36-byte key.

Layout: key = AES-128 key (16 bytes) || HMAC-SHA1 key (20 bytes); each 4096-byte
block N uses CBC with IV = HMAC-SHA1(hmac_key, big-endian N)[:16].
"""
import hashlib, hmac, struct, sys
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

src, dst, keyhex = sys.argv[1:4]
key = bytes.fromhex(keyhex)
if len(key) != 36: sys.exit("key must be 36 bytes")
aes_key, hkey = key[:16], key[16:]
with open(src, 'rb') as f:
    hdr = f.read(0x80)
    assert hdr[:8] == b'encrcdsa', 'not encrcdsa'
    blocksize = struct.unpack('>I', hdr[0x34:0x38])[0]
    datasize = struct.unpack('>Q', hdr[0x38:0x40])[0]
    offset = struct.unpack('>Q', hdr[0x40:0x48])[0]
    f.seek(offset)
    out = open(dst, 'wb')
    n = 0; remaining = datasize
    while remaining > 0:
        chunk = f.read(min(blocksize, remaining))
        if not chunk: break
        iv = hmac.new(hkey, struct.pack('>I', n), hashlib.sha1).digest()[:16]
        dec = Cipher(algorithms.AES(aes_key), modes.CBC(iv)).decryptor()
        pad = len(chunk) % 16
        body = chunk[:len(chunk)-pad]
        out.write(dec.update(body) + dec.finalize()); out.write(chunk[len(chunk)-pad:])
        remaining -= len(chunk); n += 1
    out.close()
print('wrote', dst, n, 'blocks')
