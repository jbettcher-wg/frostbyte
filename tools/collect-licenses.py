#!/usr/bin/env python3
"""Copy the licence texts of everything FrostByte.app contains into one directory.

    tools/collect-licenses.py <out dir>      (normally FrostByte.app/Contents/Resources/Licenses)

Reads the licence files straight out of the verified source archives (config/sources.lock,
category deps, in $LEOPARD_DL/deps), so it does not depend on which build directory made the
stage; falls back to unpacked trees in $LEOPARD_BUILD/deps/src. WebKit's come from the patched
tree, or from the WebKit archive. Writes
<out>/<package>/<licence files>, plus FrostByte's own LICENSE and NOTICE at the top. Fails if a
package that was built has no licence file it can find, so a new dependency cannot slip in
without one.
"""
import os
import re
import shutil
import sys
import tarfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.environ.get("LEOPARD_BUILD", os.path.join(ROOT, "build"))
DL = os.environ.get("LEOPARD_DL", os.path.join(os.path.expanduser("~"), ".cache", "frostbyte", "dl"))
NAMES = re.compile(r"^(COPYING|LICEN[CS]E|COPYRIGHT|Copyright|PATENTS|NOTICE|AUTHORS\.LICENSE)([._-].*)?$|^FTL\.TXT$|^GPLv2\.TXT$")
# WebKit's licence files and those of the third-party code compiled into it (everything named
# LICENSE*/COPYING* under Source/, minus code FrostByte does not build: gtest, the x86/ARM
# disassemblers).
WEBKIT_SKIP = re.compile(r"/(gtest|zydis|ARM64|libsysprof-capture)/")


def licence_files(src):
    found = []
    for name in sorted(os.listdir(src)):
        p = os.path.join(src, name)
        if os.path.isfile(p) and NAMES.match(name):
            found.append(p)
    docs = os.path.join(src, "docs")   # FreeType keeps FTL.TXT/GPLv2.TXT here
    if os.path.isdir(docs):
        found += [os.path.join(docs, n) for n in sorted(os.listdir(docs)) if NAMES.match(n)]
    return found


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    out = argv[1]
    os.makedirs(out, exist_ok=True)
    for f in ("LICENSE", "NOTICE"):
        shutil.copy(os.path.join(ROOT, f), os.path.join(out, "FrostByte-" + f + ".txt"))
    missing = []
    done = set()
    archives = []
    for line in open(os.path.join(ROOT, "config", "sources.lock")):
        f = line.split()
        if len(f) >= 4 and f[0] == "deps" and re.search(r"\.(tar\.(gz|xz|bz2)|tgz)$", f[1]):
            archives.append(os.path.join(DL, "deps", f[1]))
    for path in archives:
        if not os.path.isfile(path):
            continue
        got = 0
        with tarfile.open(path) as t:
            for m in t:
                parts = m.name.split("/")
                if not (m.isfile() or m.issym()) or not (NAMES.match(parts[-1]) or (len(parts) == 3 and parts[1] == "LICENSES")):
                    continue
                if not (len(parts) == 2 or (len(parts) == 3 and parts[1] in ("docs", "source", "LICENSES"))):
                    continue
                if m.issym():   # e.g. GLib's COPYING -> LICENSES/LGPL-2.1-or-later.txt (copied anyway)
                    continue
                top = parts[0]
                os.makedirs(os.path.join(out, top), exist_ok=True)
                with t.extractfile(m) as src, open(os.path.join(out, top, os.path.basename(parts[-1])), "wb") as dst:
                    shutil.copyfileobj(src, dst)
                done.add(top)
                got += 1
        name = os.path.basename(path)
        if got == 0 and name.startswith("sqlite-"):
            top = re.sub(r"\.(tar\.(gz|xz|bz2)|tgz)$", "", name)
            os.makedirs(os.path.join(out, top), exist_ok=True)
            open(os.path.join(out, top, "LICENSE.txt"), "w").write(
                "SQLite is in the public domain. The author disclaims copyright; see the header of sqlite3.c\n"
                "in %s and https://www.sqlite.org/copyright.html.\n" % name)
            done.add(top)
            got = 1
        if got == 0:
            missing.append(name)
    srcs = []
    deps = os.path.join(BUILD, "deps", "src")
    if os.path.isdir(deps):
        srcs += [(n, os.path.join(deps, n)) for n in sorted(os.listdir(deps)) if not n.startswith(".") and n not in done]
    for name, src in srcs:
        files = licence_files(src)
        if not files:
            missing.append(name)
            continue
        os.makedirs(os.path.join(out, name), exist_ok=True)
        for f in files:
            shutil.copy(f, os.path.join(out, name, os.path.basename(f)))
        done.add(name)
    wk = os.path.join(BUILD, "src", "wpewebkit-2.54.1")
    if os.path.isdir(wk):
        d = os.path.join(out, "wpewebkit-2.54.1")
        os.makedirs(d, exist_ok=True)
        for dirpath, dirs, files in os.walk(os.path.join(wk, "Source")):
            for n in files:
                p = os.path.join(dirpath, n)
                rel = os.path.relpath(p, os.path.join(wk, "Source"))
                if re.match(r"^(LICEN[CS]E|COPYING)", n) and not WEBKIT_SKIP.search("/" + rel):
                    shutil.copy(p, os.path.join(d, rel.replace("/", "_")))
        shutil.copy(os.path.join(wk, "Source/ThirdParty/xdgmime/README"), os.path.join(d, "ThirdParty_xdgmime_README"))
    else:
        wka = os.path.join(DL, "wpe", "wpewebkit-2.54.1.tar.xz")
        if not os.path.isfile(wka):
            missing.append("wpewebkit-2.54.1")
        else:
            d = os.path.join(out, "wpewebkit-2.54.1")
            os.makedirs(d, exist_ok=True)
            with tarfile.open(wka) as t:
                for m in t:
                    rel = m.name.split("/", 1)[-1]
                    n = rel.rsplit("/", 1)[-1]
                    if m.isfile() and rel.startswith("Source/") and (re.match(r"^(LICEN[CS]E|COPYING)", n) or rel == "Source/ThirdParty/xdgmime/README") \
                            and not WEBKIT_SKIP.search("/" + rel):
                        with t.extractfile(m) as src, open(os.path.join(d, rel[len("Source/"):].replace("/", "_")), "wb") as dst:
                            shutil.copyfileobj(src, dst)
    for n in missing:
        print("collect-licenses: no licence file found for " + n, file=sys.stderr)
    print("licences of %d components in %s" % (len(done) + 1, out))
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
