# patches/: the WebKit port

`leopard-darwin9-wpe-2.54.1-full.patch` turns the vanilla WPE WebKit 2.54.1
release (`wpewebkit-2.54.1.tar.xz`, pinned in `config/sources.lock`) into
FrostByte's WebKit: Mac OS X 10.5 (Darwin 9) support, big-endian 64-bit
PowerPC, JavaScriptCore's LLInt, Baseline, DFG and FTL JIT tiers and WebAssembly
BBQ on PowerPC (Darwin ABI; the e6500 instruction set, with the PowerPC 970
profile for the G5 being added), Skia's AltiVec and
big-endian fixes, the Unix-socket IPC changes, and FrostByte's bytecode cache and
parser work. It is one patch, applied with `patch -p1`, generated from the
working tree by `tools/regen-wpe-patch.sh`.

`./build.sh fetch` unpacks the tarball into `build/src/wpewebkit-2.54.1` and
applies every `*.patch` here in name order; it re-creates the tree whenever the
tarball or a patch changes.

To change WebKit: edit `build/src/wpewebkit-2.54.1`, build, then run
`tools/regen-wpe-patch.sh` and commit the patch. What each part of the port does
and why is in the comments the patch adds.
