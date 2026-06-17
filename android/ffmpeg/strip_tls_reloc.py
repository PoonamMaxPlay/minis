#!/usr/bin/env python3
"""
Neutralise the lone R_AARCH64_TLS_TPREL64 reloc + STATIC_TLS DT flag in an
FFmpeg .so. Compiler-rt pulls in a single 8-byte __thread variable used by
exception unwinding; FFmpeg never reaches that code path, but the reloc's
presence makes Android's dynamic linker refuse the dlopen with:

    "TLS symbol (null) ... using IE access model"

Rewriting the reloc type to R_AARCH64_NONE (0) and clearing the STATIC_TLS bit
in DT_FLAGS makes the lib load. No FFmpeg public symbol is affected.
"""
import sys
import struct

path = sys.argv[1]
with open(path, 'rb') as f:
    data = bytearray(f.read())

assert data[4] == 2, "ELF64 only"

e_phoff = struct.unpack_from('<Q', data, 0x20)[0]
e_shoff = struct.unpack_from('<Q', data, 0x28)[0]
e_phentsize = struct.unpack_from('<H', data, 0x36)[0]
e_phnum = struct.unpack_from('<H', data, 0x38)[0]
e_shentsize = struct.unpack_from('<H', data, 0x3a)[0]
e_shnum = struct.unpack_from('<H', data, 0x3c)[0]
e_shstrndx = struct.unpack_from('<H', data, 0x3e)[0]

shstr_off = struct.unpack_from('<Q', data, e_shoff + e_shstrndx * e_shentsize + 0x18)[0]


def section_name(name_off):
    end = data.index(0, shstr_off + name_off)
    return data[shstr_off + name_off:end].decode()


rela_off = rela_size = 0
for i in range(e_shnum):
    base = e_shoff + i * e_shentsize
    name_off = struct.unpack_from('<I', data, base)[0]
    if section_name(name_off) == '.rela.dyn':
        rela_off = struct.unpack_from('<Q', data, base + 0x18)[0]
        rela_size = struct.unpack_from('<Q', data, base + 0x20)[0]
        break

R_AARCH64_TLS_TPREL64 = 0x406
patched = 0
if rela_off:
    for i in range(rela_size // 24):
        o = rela_off + i * 24
        r_info = struct.unpack_from('<Q', data, o + 8)[0]
        if r_info == R_AARCH64_TLS_TPREL64:
            struct.pack_into('<Q', data, o + 8, 0)
            patched += 1

dt_cleared = 0
for i in range(e_phnum):
    base = e_phoff + i * e_phentsize
    p_type = struct.unpack_from('<I', data, base)[0]
    if p_type == 2:
        dyn_off = struct.unpack_from('<Q', data, base + 8)[0]
        dyn_size = struct.unpack_from('<Q', data, base + 0x20)[0]
        o = dyn_off
        while o < dyn_off + dyn_size:
            tag = struct.unpack_from('<Q', data, o)[0]
            val = struct.unpack_from('<Q', data, o + 8)[0]
            if tag == 0:
                break
            if tag == 0x1e and (val & 0x10):
                struct.pack_into('<Q', data, o + 8, val & ~0x10)
                dt_cleared += 1
            o += 16
        break

with open(path, 'wb') as f:
    f.write(data)

print(f"{path}: TPREL64 cleared={patched} STATIC_TLS cleared={dt_cleared}")
