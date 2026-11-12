#!/usr/bin/env python3
"""Package a self-contained FrostByte.app for a stock Mac OS X 10.5.8 ppc64 machine.

    LEOPARD_TARGET=g5 python3 -I tools/package-app.py [--out DIR]

Inputs (all per build profile, toolchain/target.sh):
    stage-wpe<suffix>/opt/wpe      the dependency stack plus `ninja install` of WebKit
    frostbyte/build<suffix>/        frostbyte-shell from frostbyte/build.sh
    frostbyte/resources/            Info.plist, icons, toolbar and tab art

Output: <out>/FrostByte.app (default dist/FrostByte<suffix>/FrostByte.app), laid out as

    Contents/MacOS/FrostByte
    Contents/Libexec/{WPEWebProcess,WPENetworkProcess,gst-plugin-scanner}
    Contents/Frameworks/*.dylib                     every /opt/wpe library the above need
    Contents/Frameworks/gstreamer-1.0/*.dylib       GStreamer plugins
    Contents/Frameworks/gio/modules/libgiognutls.so TLS for GIO
    Contents/Frameworks/wpe-webkit-2.0/injected-bundle/
    Contents/Resources/etc/{fonts,ssl}, Contents/Resources/share/mime, icons and art

Every reference to /opt/wpe/lib/X becomes @loader_path/<relative path to Frameworks/X>
(@loader_path: Leopard's dyld 97 supports it in load commands and dlopen; no @rpath, which
needs LC_RPATH bookkeeping for no benefit here). Library ids become
@executable_path/../Frameworks/X. Everything that GLib, GStreamer, fontconfig, GnuTLS and
WebKit find by path at run time is pointed into the bundle by FrostByte at startup
(fb-hardware.m, setupBundledRuntime). Every executable gets tools/fix-ppc64-entry.py after
its load commands are rewritten. tools/check-bundle.py verifies the result.
"""
import argparse, os, shutil, struct, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Paths are relative to this script's tree (ROOT) or come from the environment, so the tool works
# from any checkout: LEOPARD_CCTOOLS (directory holding powerpc-apple-darwin9-install_name_tool),
# else $LEOPARD_TOOLCHAIN/bin (toolchain/wpe-env.sh exports it).
TC = os.path.join(os.environ.get('LEOPARD_CCTOOLS', os.path.join(os.environ.get('LEOPARD_TOOLCHAIN', ''), 'bin')),
                  'powerpc-apple-darwin9-')
INSTALL_NAME_TOOL = TC + 'install_name_tool'
PREFIX = '/opt/wpe'

SUFFIXES = {'t4240': '', 'g5': '-g5', 'generic': '-generic'}
# GStreamer plugins not shipped: the UVD decoder is not built for release, and gstgl's
# EGL module path is compiled in (/opt/wpe/lib/libEGL.1.dylib); WebKit is built without
# GStreamer GL, so nothing asks for them.
SKIP_PLUGINS = {'libgstrdnvd.dylib', 'libgstopengl.dylib'}

LC_REQ_DYLD = 0x80000000
LOAD_CMDS = {0xc, 0x18 | LC_REQ_DYLD, 0x1f | LC_REQ_DYLD, 0x20, 0x23 | LC_REQ_DYLD}  # load, weak, reexport, lazy, upward
LC_ID_DYLIB = 0xd


def macho_info(path):
    """(filetype, [dylib refs], id) for a thin big-endian 64-bit Mach-O, else None."""
    with open(path, 'rb') as f:
        head = f.read(32)
        if len(head) < 32 or struct.unpack('>I', head[:4])[0] != 0xFEEDFACF:
            return None
        _, _, _, filetype, ncmds, sizeofcmds, _, _ = struct.unpack('>IiiIIIII', head)
        cmds = f.read(sizeofcmds)
    refs, ident, o = [], None, 0
    for _ in range(ncmds):
        cmd, size = struct.unpack('>II', cmds[o:o + 8])
        if cmd in LOAD_CMDS or cmd == LC_ID_DYLIB:
            off, = struct.unpack('>I', cmds[o + 8:o + 12])
            name = cmds[o + off:o + size].split(b'\0', 1)[0].decode()
            if cmd == LC_ID_DYLIB:
                ident = name
            else:
                refs.append(name)
        o += size
    return filetype, refs, ident


def run(*args):
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f'{" ".join(args)}: {r.stderr.strip()}')


def main():
    target = os.environ.get('LEOPARD_TARGET', 'generic')
    if target not in SUFFIXES:
        sys.exit('LEOPARD_TARGET must be t4240, g5 or generic')
    sfx = SUFFIXES[target]
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=os.path.join(os.environ.get('LEOPARD_BUILD', os.path.join(ROOT, 'build')), 'dist', 'FrostByte' + sfx))
    ap.add_argument('--stage', default=os.path.join(os.environ.get('LEOPARD_BUILD', os.path.join(ROOT, 'build')), 'stage-wpe' + sfx) + PREFIX)
    ap.add_argument('--shell', default=os.path.join(ROOT, 'frostbyte', 'build' + sfx, 'frostbyte-shell'))
    ap.add_argument('--resources', default=os.path.join(ROOT, 'frostbyte', 'resources'))
    a = ap.parse_args()
    stage, res = a.stage, a.resources

    app = os.path.join(a.out, 'FrostByte.app')
    if os.path.exists(app):
        shutil.rmtree(app)
    C = os.path.join(app, 'Contents')
    FW, LX, RS, MO = (os.path.join(C, d) for d in ('Frameworks', 'Libexec', 'Resources', 'MacOS'))
    for d in (FW, LX, RS, MO):
        os.makedirs(d)

    placed = {}   # bundle path -> kind ('exe' or 'lib')

    def put(src, dst, kind):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(os.path.realpath(src), dst)
        os.chmod(dst, 0o755)
        placed[dst] = kind

    # roots
    put(a.shell, os.path.join(MO, 'FrostByte'), 'exe')
    for p in ('WPEWebProcess', 'WPENetworkProcess'):
        put(os.path.join(stage, 'libexec/wpe-webkit-2.0', p), os.path.join(LX, p), 'exe')
    put(os.path.join(stage, 'libexec/gstreamer-1.0/gst-plugin-scanner'), os.path.join(LX, 'gst-plugin-scanner'), 'exe')
    gst = os.path.join(stage, 'lib/gstreamer-1.0')
    for n in sorted(os.listdir(gst)):
        if n.endswith('.dylib') and n not in SKIP_PLUGINS:
            put(os.path.join(gst, n), os.path.join(FW, 'gstreamer-1.0', n), 'lib')
    put(os.path.join(stage, 'lib/gio/modules/libgiognutls.so'), os.path.join(FW, 'gio/modules/libgiognutls.so'), 'lib')
    ib = os.path.join(stage, 'lib/wpe-webkit-2.0/injected-bundle/libWPEInjectedBundle.so')
    if os.path.exists(ib):
        put(ib, os.path.join(FW, 'wpe-webkit-2.0/injected-bundle/libWPEInjectedBundle.so'), 'lib')
    # LeopardEGL and GLES: libepoxy dlopens them as @loader_path/libEGL.1.dylib / libGLESv2.2.dylib.
    for n in ('libEGL.1.dylib', 'libGLESv2.2.dylib'):
        put(os.path.join(stage, 'lib', n), os.path.join(FW, n), 'lib')

    # closure over /opt/wpe/lib references
    work = list(placed)
    while work:
        f = work.pop()
        info = macho_info(f)
        if not info:
            continue
        for ref in info[1]:
            if ref.startswith(PREFIX + '/lib/'):
                rel = ref[len(PREFIX) + 5:]
                dst = os.path.join(FW, rel)
                if dst not in placed:
                    src = os.path.join(stage, 'lib', rel)
                    if not os.path.exists(src):
                        sys.exit(f'{f}: needs {ref}, not in {stage}')
                    put(src, dst, 'lib')
                    work.append(dst)

    # rewrite install names, then fix executables' entry points
    for f, kind in sorted(placed.items()):
        info = macho_info(f)
        if not info:
            continue
        args = []
        if info[2]:
            relid = os.path.relpath(f, FW)
            args += ['-id', '@executable_path/../Frameworks/' + relid]
        for ref in info[1]:
            if ref.startswith(PREFIX + '/lib/'):
                target_path = os.path.join(FW, ref[len(PREFIX) + 5:])
                args += ['-change', ref, '@loader_path/' + os.path.relpath(target_path, os.path.dirname(f))]
        if args:
            run(INSTALL_NAME_TOOL, *args, f)
        if kind == 'exe':
            run(sys.executable, '-I', os.path.join(ROOT, 'tools/fix-ppc64-entry.py'), f)

    # data the runtime finds by path
    shutil.copy(os.path.join(res, 'Info.plist'), os.path.join(C, 'Info.plist'))
    with open(os.path.join(C, 'PkgInfo'), 'w') as f:
        f.write('APPLFrBy')
    for d in ('toolbar', 'tabs'):
        shutil.copytree(os.path.join(res, d), os.path.join(RS, d))
    icns = os.path.join(res, 'icon/FrostByte.icns')
    shutil.copy(icns, os.path.join(RS, 'FrostByte.icns'))
    shutil.copy(icns, os.path.join(RS, 'FrostByte-cube2.icns'))   # CFBundleIconFile
    etc = os.path.join(RS, 'etc')
    os.makedirs(os.path.join(etc, 'fonts/conf.d'))
    confd = os.path.join(stage, 'etc/fonts/conf.d')
    for n in sorted(os.listdir(confd)):
        shutil.copyfile(os.path.realpath(os.path.join(confd, n)), os.path.join(etc, 'fonts/conf.d', n))
    conf = open(os.path.join(stage, 'etc/fonts/fonts.conf')).read()
    conf = conf.replace('<cachedir>%s/var/cache/fontconfig</cachedir>' % PREFIX,
                        '<cachedir>~/Library/Caches/org.frostbyte.FrostByte/fontconfig</cachedir>')
    if PREFIX in conf:
        sys.exit('fonts.conf still mentions ' + PREFIX)
    open(os.path.join(etc, 'fonts/fonts.conf'), 'w').write(conf)
    shutil.copytree(os.path.join(stage, 'etc/ssl'), os.path.join(etc, 'ssl'))
    shutil.copytree(os.path.join(stage, 'share/mime'), os.path.join(RS, 'share/mime'))
    insp = os.path.join(stage, 'share/wpe-webkit-2.0')
    if os.path.isdir(insp):
        shutil.copytree(insp, os.path.join(RS, 'share/wpe-webkit-2.0'))

    nlib = sum(1 for k in placed.values() if k == 'lib')
    nexe = sum(1 for k in placed.values() if k == 'exe')
    size = sum(os.path.getsize(os.path.join(dp, n)) for dp, _, ns in os.walk(app) for n in ns)
    print(f'{app}: {nexe} executables, {nlib} libraries and modules, {size >> 20} MB ({target})')


if __name__ == '__main__':
    main()
