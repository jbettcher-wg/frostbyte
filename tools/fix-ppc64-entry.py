#!/usr/bin/env python3
"""Repair two things ld64 253.9 gets wrong in a ppc64 Mach-O for Leopard.

1. LC_UNIXTHREAD srr0 (the entry point) is written as a 32-bit value in the
   wrong half of the 64-bit field.
2. Classic external/local relocation r_address fields are written relative to
   the image base, but Leopard's dyld 97.1 applies 64-bit relocations relative
   to the FIRST WRITABLE SEGMENT (ImageLoaderMachO::getRelocBase, ppc64 and
   x86_64 arms), so every fixup lands __TEXT-size bytes too high, in
   __LINKEDIT, and dyld dies with KERN_PROTECTION_FAILURE in
   doBindExternalRelocations (measured 2026-11-07 on a static-libstdc++ C++
   binary; a C binary has no such relocations and never showed it).
   Rebased here by subtracting (first writable vmaddr - image base) from each
   r_address that still points past the writable segments.

ld64 stores a ppc64 executable's LC_UNIXTHREAD srr0 as a 32-bit value in the
wrong half of the 64-bit field (0x000014a000000000 for an entry of
0x1000014a0), so the kernel jumps to garbage. This rewrites the field with
the address of the `start` symbol (crt1.o) or `__start` (-nostdlib), read from
the binary's own symbol table. Idempotent; thin ppc64 Mach-O only.

    fix-ppc64-entry.py <binary>...
"""
import struct, sys

MH_MAGIC_64 = 0xFEEDFACF
LC_SYMTAB, LC_UNIXTHREAD = 0x2, 0x5

def entry_from_symtab(d, off, n):
    o = off
    for _ in range(n):
        c, sz = struct.unpack('>II', d[o:o+8])
        if c == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack('>IIII', d[o+8:o+24])
            cands = {}
            for i in range(nsyms):
                s = symoff + i * 16
                strx, typ, sect, desc, value = struct.unpack('>IBBHQ', d[s:s+16])
                end = d.index(b'\0', stroff + strx)
                name = d[stroff+strx:end]
                if name in (b'start', b'__start') and (typ & 0x0e) == 0x0e:
                    cands[bytes(name)] = value
            return cands.get(b'start') or cands.get(b'__start')
        o += sz
    return None

LC_SEGMENT_64, LC_DYSYMTAB = 0x19, 0xB

def fix_relocs(d, n):
    """Rebase classic relocations onto the first writable segment. Returns
    (fixed, total) or None if nothing to do."""
    o, segs, dysym = 32, [], None
    for _ in range(n):
        c, sz = struct.unpack('>II', d[o:o+8])
        if c == LC_SEGMENT_64:
            name = d[o+8:o+24].rstrip(b'\0')
            vmaddr, vmsize = struct.unpack('>QQ', d[o+24:o+40])
            initprot, = struct.unpack('>I', d[o+60:o+64])
            segs.append((name, vmaddr, vmsize, initprot))
        elif c == LC_DYSYMTAB:
            dysym = o
        o += sz
    if dysym is None: return None
    base = next((a for nm, a, s, p in segs if nm != b'__PAGEZERO'), None)
    wr = next(((a, s) for nm, a, s, p in segs if nm != b'__PAGEZERO' and p & 2), None)
    if base is None or wr is None: return None
    delta = wr[0] - base
    if delta == 0: return (0, 0)
    extreloff, nextrel, locreloff, nlocrel = struct.unpack('>IIII', d[dysym+64:dysym+80])
    fixed = total = 0
    for off, cnt in ((extreloff, nextrel), (locreloff, nlocrel)):
        for i in range(cnt):
            r = off + i * 8
            r_address, info = struct.unpack('>iI', d[r:r+8])
            if info & 0x80000000:   # scattered: r_address is in the other word; leave alone
                continue
            total += 1
            target = wr[0] + r_address
            if not (wr[0] <= target < wr[0] + wr[1]) and wr[0] <= target - delta < wr[0] + wr[1]:
                struct.pack_into('>i', d, r, r_address - delta)
                fixed += 1
    return (fixed, total)

def fix(path):
    d = bytearray(open(path, 'rb').read())
    magic, = struct.unpack('>I', d[0:4])
    if magic != MH_MAGIC_64:
        print(f'{path}: not a big-endian 64-bit Mach-O, skipped'); return 0
    n, = struct.unpack('>I', d[16:20])
    entry = entry_from_symtab(d, 32, n)
    if entry is None:
        print(f'{path}: no start/__start symbol (stripped?), cannot fix'); return 1
    msgs = []
    r = fix_relocs(d, n)
    if r and r[1]:
        msgs.append(f'relocs rebased {r[0]}/{r[1]}')
    o = 32
    found = False
    for _ in range(n):
        c, sz = struct.unpack('>II', d[o:o+8])
        if c == LC_UNIXTHREAD:
            found = True
            was, = struct.unpack('>Q', d[o+16:o+24])
            if was != entry:
                struct.pack_into('>Q', d, o+16, entry)
                msgs.append(f'srr0 0x{was:016x} -> 0x{entry:016x}')
            else:
                msgs.append(f'srr0 already 0x{entry:x}')
        o += sz
    if not found:
        print(f'{path}: no LC_UNIXTHREAD'); return 1
    open(path, 'wb').write(d)
    print(f'{path}: ' + ', '.join(msgs)); return 0

if __name__ == '__main__':
    sys.exit(sum(fix(p) for p in sys.argv[1:]))
