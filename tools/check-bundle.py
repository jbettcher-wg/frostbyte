#!/usr/bin/env python3
"""Verify that a FrostByte.app runs on a stock Mac OS X 10.5.8 ppc64 machine with nothing else installed.

    python3 -I tools/check-bundle.py [--isa g5|generic|none] [--sdk DIR] FrostByte.app
    (LLVM's llvm-objdump on PATH for --isa; LEOPARD_SDK locates the 10.5 SDK)

Errors (exit status 1):
  - a Mach-O that is not thin big-endian ppc64 (fat files, ppc, i386 slices)
  - a load command naming /opt/wpe or any path outside /usr/lib and /System/Library
  - a /usr/lib or /System/Library reference that the 10.5 SDK does not have with a ppc64 slice
    (the SDK's stubs are exactly what a stock 10.5.8 install provides)
  - an @loader_path/@executable_path reference that does not resolve inside the bundle; @rpath
  - an executable whose LC_UNIXTHREAD srr0 is not its `start` symbol, or whose classic
    relocations still need tools/fix-ppc64-entry.py (Leopard's dyld would crash)
  - a text resource (fonts.conf, ...) that mentions /opt/wpe
  - with --isa: an instruction the target CPU lacks (g5: the PowerPC 970, so no isel, popcnt*,
    ldbrx/stdbrx, lbarx/lharx, cmpb, fcpsgn, fri*, VSX...; generic additionally no fsqrt/fsqrts,
    which the e6500 traps on)
Warnings: compiled-in /opt/wpe strings inside binaries (FrostByte overrides those defaults through
the environment at startup; listed so a new one gets noticed), references to /usr/lib/libiconv.
"""
import argparse, os, re, struct, subprocess, sys

# The 10.5 SDK: --sdk, else $LEOPARD_SDK (toolchain/wpe-env.sh exports it).
SDK = os.environ.get('LEOPARD_SDK', '')
CPU_TYPE_POWERPC64 = 0x01000012
MH_EXECUTE = 2
LC_REQ_DYLD = 0x80000000
LOAD_CMDS = {0xc: 'LC_LOAD_DYLIB', 0x18 | LC_REQ_DYLD: 'LC_LOAD_WEAK_DYLIB', 0x1f | LC_REQ_DYLD: 'LC_REEXPORT_DYLIB',
             0x20: 'LC_LAZY_LOAD_DYLIB', 0x23 | LC_REQ_DYLD: 'LC_LOAD_UPWARD_DYLIB'}
LC_ID_DYLIB, LC_LOAD_DYLINKER, LC_RPATH = 0xd, 0xe, 0x1c | LC_REQ_DYLD
LC_SYMTAB, LC_UNIXTHREAD, LC_SEGMENT_64, LC_DYSYMTAB = 0x2, 0x5, 0x19, 0xb

# Instructions the PowerPC 970 does not have (llvm-objdump mnemonics, decoded as POWER7 so they
# are recognised at all). VSX and later families are matched by prefix below.
NOT_ON_970 = {'isel', 'popcntb', 'popcntw', 'popcntd', 'cmpb', 'ldbrx', 'stdbrx', 'lbarx', 'lharx', 'stbcx.',
              'sthcx.', 'prtyw', 'prtyd', 'bpermd', 'divde', 'divdeu', 'divwe', 'divweu', 'divde.', 'divdeu.',
              'divwe.', 'divweu.', 'fcpsgn', 'fcpsgn.', 'lfiwax', 'lfiwzx', 'frin', 'friz', 'frip', 'frim',
              'fcfidu', 'fcfids', 'fcfidus', 'fctiwu', 'fctiwuz', 'fctidu', 'fctiduz', 'fre', 'fre.',
              'frsqrtes', 'frsqrtes.', 'ftdiv', 'ftsqrt', 'wait', 'isel', 'mfvsrd', 'mtvsrd', 'mfvsrwz',
              'mtvsrwa', 'mtvsrwz', 'ldmx', 'cnttzw', 'cnttzd', 'modsw', 'moduw', 'modsd', 'modud',
              'setb', 'darn', 'cmpeqb', 'cmprb', 'maddld', 'maddhd', 'maddhdu', 'addpcis', 'extswsli'}
VSX_PREFIXES = ('xs', 'xv', 'xx', 'lxv', 'stxv', 'lxs', 'stxs', 'lxsi', 'stxsi')
NOT_ON_E6500_TOO = {'fsqrt', 'fsqrt.', 'fsqrts', 'fsqrts.'}   # generic: must also run on the e6500


def read_macho(path):
    with open(path, 'rb') as f:
        d = f.read()
    return d


def kind(d):
    if len(d) < 4:
        return None
    m = struct.unpack('>I', d[:4])[0]
    if m == 0xFEEDFACF:
        return 'ppc64' if struct.unpack('>i', d[4:8])[0] == CPU_TYPE_POWERPC64 else 'be64-other'
    if m in (0xCAFEBABE,):
        return 'fat' if len(d) > 8 and struct.unpack('>I', d[4:8])[0] < 32 else None   # Java class files share the magic
    if m in (0xFEEDFACE, 0xCEFAEDFE, 0xCFFAEDFE):
        return 'thin-other'
    return None


def commands(d):
    _, _, _, filetype, ncmds, _, _, _ = struct.unpack('>IiiIIIII', d[:32])
    o, out = 32, []
    for _ in range(ncmds):
        cmd, size = struct.unpack('>II', d[o:o + 8])
        out.append((cmd, o, size))
        o += size
    return filetype, out


def lc_string(d, o, size):
    off, = struct.unpack('>I', d[o + 8:o + 12])
    return d[o + off:o + size].split(b'\0', 1)[0].decode()


def start_symbol(d, cmds):
    for cmd, o, _ in cmds:
        if cmd == LC_SYMTAB:
            symoff, nsyms, stroff, _ = struct.unpack('>IIII', d[o + 8:o + 24])
            found = {}
            for i in range(nsyms):
                s = symoff + i * 16
                strx, typ, _, _, value = struct.unpack('>IBBHQ', d[s:s + 16])
                if typ & 0x0e != 0x0e:
                    continue
                name = d[stroff + strx:d.index(b'\0', stroff + strx)]
                if name in (b'start', b'__start'):
                    found[name] = value
            return found.get(b'start') or found.get(b'__start')
    return None


def relocs_needing_fix(d, cmds):
    """Classic relocations ld64 left image-relative (tools/fix-ppc64-entry.py rebases them)."""
    segs, dysym = [], None
    for cmd, o, _ in cmds:
        if cmd == LC_SEGMENT_64:
            name = d[o + 8:o + 24].rstrip(b'\0')
            vmaddr, vmsize = struct.unpack('>QQ', d[o + 24:o + 40])
            initprot, = struct.unpack('>I', d[o + 60:o + 64])
            segs.append((name, vmaddr, vmsize, initprot))
        elif cmd == LC_DYSYMTAB:
            dysym = o
    if dysym is None:
        return 0
    base = next((a for n, a, s, p in segs if n != b'__PAGEZERO'), None)
    wr = next(((a, s) for n, a, s, p in segs if n != b'__PAGEZERO' and p & 2), None)
    if base is None or wr is None or wr[0] == base:
        return 0
    delta = wr[0] - base
    extreloff, nextrel, locreloff, nlocrel = struct.unpack('>IIII', d[dysym + 64:dysym + 80])
    bad = 0
    for off, cnt in ((extreloff, nextrel), (locreloff, nlocrel)):
        for i in range(cnt):
            r_address, info = struct.unpack('>iI', d[off + i * 8:off + i * 8 + 8])
            if info & 0x80000000:
                continue
            t = wr[0] + r_address
            if not (wr[0] <= t < wr[0] + wr[1]) and wr[0] <= t - delta < wr[0] + wr[1]:
                bad += 1
    return bad


def sdk_has_ppc64(path, sdk):
    p = sdk + path
    if not os.path.exists(p):
        return False
    with open(os.path.realpath(p), 'rb') as f:
        h = f.read(4096)
    m = struct.unpack('>I', h[:4])[0]
    if m == 0xFEEDFACF:
        return struct.unpack('>i', h[4:8])[0] == CPU_TYPE_POWERPC64
    if m == 0xCAFEBABE:
        n, = struct.unpack('>I', h[4:8])
        return any(struct.unpack('>i', h[8 + 20 * i:12 + 20 * i])[0] == CPU_TYPE_POWERPC64 for i in range(n))
    return False


def isa_scan(path, isa):
    # GCC on Darwin/PPC puts switch jump tables (32-bit signed offsets) in __text, right after
    # the bctr. llvm-objdump decodes them too: 0xffffxxxx is an opcode-63 word (xs*qp, fcpsgn...),
    # 0x0000xxxx an illegal one. No real instruction the scan cares about has 0x0000 or 0xffff
    # as its high halfword, so those words are skipped.
    r = subprocess.run(['llvm-objdump', '-d', '--mcpu=pwr7', path], capture_output=True, text=True)
    bad = {}
    forbidden = NOT_ON_970 | (NOT_ON_E6500_TOO if isa == 'generic' else set())
    for line in r.stdout.splitlines():
        parts = line.split('\t')
        if len(parts) < 2 or ':' not in parts[0]:
            continue
        raw = parts[0].split(':', 1)[1].split()
        if len(raw) == 4 and (raw[:2] == ['ff', 'ff'] or raw[:2] == ['00', '00']):
            continue
        mn = parts[1].split(' ', 1)[0].strip()
        if mn in forbidden or mn.startswith(VSX_PREFIXES):
            bad[mn] = bad.get(mn, 0) + 1
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('app')
    ap.add_argument('--isa', choices=['g5', 'generic', 'none'], default='none')
    ap.add_argument('--sdk', default=SDK)
    a = ap.parse_args()
    app = os.path.abspath(a.app.rstrip('/'))
    contents = os.path.join(app, 'Contents')
    errors, warnings = [], []
    nmacho = nexe = 0
    opt_strings = {}
    sysrefs = set()

    def err(m): errors.append(m)

    plist = os.path.join(contents, 'Info.plist')
    if not os.path.exists(plist):
        err('Contents/Info.plist missing')
    else:
        m = re.search(r'<key>CFBundleExecutable</key>\s*<string>([^<]+)</string>', open(plist).read())
        if not m or not os.path.exists(os.path.join(contents, 'MacOS', m.group(1))):
            err('CFBundleExecutable missing from Contents/MacOS')

    for dp, _, names in os.walk(app):
        for n in sorted(names):
            f = os.path.join(dp, n)
            rel = os.path.relpath(f, app)
            if os.path.islink(f):
                t = os.path.realpath(f)
                if not t.startswith(app + os.sep):
                    err(f'{rel}: symlink leaves the bundle ({os.readlink(f)})')
                continue
            d = read_macho(f)
            k = kind(d)
            if k is None:
                if n.endswith(('.conf', '.plist', '.pem', '.xml', '.txt')) and b'/opt/wpe' in d:
                    err(f'{rel}: text resource mentions /opt/wpe')
                continue
            nmacho += 1
            if k != 'ppc64':
                err(f'{rel}: {k} Mach-O, not thin ppc64')
                continue
            filetype, cmds = commands(d)
            rpaths = [lc_string(d, o, s) for c, o, s in cmds if c == LC_RPATH]
            for c, o, s in cmds:
                if c == LC_LOAD_DYLINKER and lc_string(d, o, s) != '/usr/lib/dyld':
                    err(f'{rel}: dylinker {lc_string(d, o, s)}')
                if c not in LOAD_CMDS:
                    continue
                ref = lc_string(d, o, s)
                if ref.startswith('@loader_path/'):
                    t = os.path.normpath(os.path.join(os.path.dirname(f), ref[len('@loader_path/'):]))
                    if not os.path.isfile(t) or not t.startswith(app + os.sep):
                        err(f'{rel}: {ref} does not resolve inside the bundle')
                elif ref.startswith('@executable_path/'):
                    for exedir in ('MacOS', 'Libexec'):
                        t = os.path.normpath(os.path.join(contents, exedir, ref[len('@executable_path/'):]))
                        if not os.path.isfile(t):
                            err(f'{rel}: {ref} does not resolve from Contents/{exedir}')
                elif ref.startswith('@rpath/'):
                    err(f'{rel}: {ref} (@rpath; LC_RPATH {rpaths or "none"})')
                elif ref.startswith(('/usr/lib/', '/System/Library/')):
                    sysrefs.add(ref)
                    if not sdk_has_ppc64(ref, a.sdk):
                        err(f'{rel}: {ref} is not a ppc64 library of a stock 10.5.8 system (not in the 10.5 SDK)')
                    if ref.startswith('/usr/lib/libiconv'):
                        warnings.append(f'{rel}: links /usr/lib/libiconv (thin ppc on some 10.5 installs; bundle libiconv instead)')
                else:
                    err(f'{rel}: {ref} is outside the bundle and the system')
            if filetype == MH_EXECUTE:
                nexe += 1
                entry = start_symbol(d, cmds)
                srr0 = None
                for c, o, s in cmds:
                    if c == LC_UNIXTHREAD:
                        srr0, = struct.unpack('>Q', d[o + 16:o + 24])
                if entry is None:
                    err(f'{rel}: executable has no start symbol (stripped?)')
                elif srr0 != entry:
                    err(f'{rel}: LC_UNIXTHREAD srr0 0x{srr0 or 0:x} != start 0x{entry:x} (run tools/fix-ppc64-entry.py)')
                nb = relocs_needing_fix(d, cmds)
                if nb:
                    err(f'{rel}: {nb} classic relocations still image-relative (run tools/fix-ppc64-entry.py)')
            hits = d.count(b'/opt/wpe')
            if hits:
                opt_strings[rel] = hits
            if a.isa != 'none':
                bad = isa_scan(f, a.isa)
                if bad:
                    err(f'{rel}: instructions the {a.isa} target lacks: ' +
                        ', '.join(f'{m} x{c}' for m, c in sorted(bad.items(), key=lambda kv: -kv[1])[:12]))

    for rel, hits in sorted(opt_strings.items()):
        warnings.append(f'{rel}: {hits} compiled-in /opt/wpe string(s) (defaults; overridden by the environment)')
    print(f'{app}: {nmacho} Mach-O files ({nexe} executables), {len(sysrefs)} distinct system libraries')
    for r in sorted(sysrefs):
        print('  system:', r)
    for w in warnings:
        print('WARNING', w)
    for e in errors:
        print('ERROR', e)
    print('RESULT:', 'FAIL' if errors else 'PASS', f'({len(errors)} errors, {len(warnings)} warnings, isa check: {a.isa})')
    sys.exit(1 if errors else 0)


if __name__ == '__main__':
    main()
