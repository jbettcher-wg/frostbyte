#!/usr/bin/env python3
"""Digest and sanity-check a Mac OS X 10.5 SDK tree.

    tools/sdk-digest.py <MacOSX10.5.sdk>            print the tree digest
    tools/sdk-digest.py --check <MacOSX10.5.sdk>    structural checks only (exit 1 on failure)

The digest is the SHA-256 of the sha256sum-style listing of every regular file, sorted bytewise:

    find . -type f | LC_ALL=C sort | xargs -d '\\n' sha256sum | sha256sum

so it can be cross-checked with coreutils. config/sdk.lock holds the value for the SDK in Xcode
3.1.4 (build 9M2809), which is what FrostByte is built and tested against. Symlinks are not part
of the digest; --check makes sure the ones the build follows resolve.
"""
import hashlib
import os
import struct
import sys

# Files the build reads directly, and what each is for.
REQUIRED = [
    ("SDKSettings.plist", "SDK identity"),
    ("usr/include/stdio.h", "C headers"),
    ("usr/include/c++/4.0.0", "Apple libstdc++ headers"),
    ("usr/lib/libSystem.B.dylib", "libSystem link stub"),
    ("usr/lib/libstdc++.6.dylib", "Apple libstdc++ stub"),
    ("usr/lib/crt1.o", "program start-up object"),
    ("usr/lib/dylib1.o", "dylib start-up object"),
    ("System/Library/Frameworks/AppKit.framework/Headers/AppKit.h", "Cocoa (FrostByte shell)"),
    ("System/Library/Frameworks/OpenGL.framework/Headers/CGLTypes.h", "CGL (LeopardEGL)"),
    ("System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", "CoreFoundation"),
    ("System/Library/Frameworks/IOKit.framework/IOKit", "IOKit"),
]
FAT_MAGIC = 0xCAFEBABE
CPU_TYPE_POWERPC64 = 0x01000012


def tree_digest(root):
    entries = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not os.path.islink(os.path.join(dirpath, d))]
        for name in filenames:
            full = os.path.join(dirpath, name)
            if os.path.islink(full) or not os.path.isfile(full):
                continue
            rel = "./" + os.path.relpath(full, root)
            entries.append((os.fsencode(rel), full))
    entries.sort(key=lambda e: e[0])
    outer = hashlib.sha256()
    for rel, full in entries:
        h = hashlib.sha256()
        with open(full, "rb") as f:
            for block in iter(lambda: f.read(1 << 20), b""):
                h.update(block)
        outer.update(h.hexdigest().encode() + b"  " + rel + b"\n")
    return outer.hexdigest(), len(entries)


def has_ppc64_slice(path):
    with open(path, "rb") as f:
        head = f.read(8)
        if len(head) < 8:
            return False
        magic, n = struct.unpack(">II", head)
        if magic != FAT_MAGIC:
            return False
        for _ in range(n):
            cputype = struct.unpack(">iiIII", f.read(20))[0]
            if cputype == CPU_TYPE_POWERPC64:
                return True
    return False


def check(root):
    bad = []
    for rel, why in REQUIRED:
        if not os.path.exists(os.path.join(root, rel)):
            bad.append("missing %s (%s)" % (rel, why))
    libsystem = os.path.join(root, "usr/lib/libSystem.B.dylib")
    if os.path.exists(libsystem) and not has_ppc64_slice(libsystem):
        bad.append("usr/lib/libSystem.B.dylib has no ppc64 slice (not a 10.5 SDK with 64-bit PowerPC support)")
    settings = os.path.join(root, "SDKSettings.plist")
    if os.path.exists(settings):
        text = open(settings, "rb").read()
        if b"macosx10.5" not in text:
            bad.append("SDKSettings.plist does not name macosx10.5")
    return bad


def main(argv):
    if len(argv) == 3 and argv[1] == "--check":
        bad = check(argv[2])
        for b in bad:
            print("sdk: " + b, file=sys.stderr)
        return 1 if bad else 0
    if len(argv) == 2:
        digest, n = tree_digest(argv[1])
        print("%s %d" % (digest, n))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
