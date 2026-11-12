# toolchain/darwin-cross: the compiler

FrostByte is built with GCC 15.3.0 and cctools 877.8 / ld64 253.9 for
`powerpc-apple-darwin9`. This directory holds what it takes to make that
toolchain:

| File | What |
|---|---|
| `build-toolchain.sh` | builds cctools and GCC into one relocatable prefix (`--mode=cross` for Linux/macOS, `--mode=native` on Mac OS X 10.5 PowerPC, `--mode=canadian` on Linux for a toolchain that runs on 10.5) |
| `make-toolchain-tarball.sh` | packs a toolchain (without anything from the SDK) into the prebuilt tarball `./build.sh` downloads |
| `patches/gcc/` | applied to GCC 15.3.0, in name order |
| `patches/cctools/` | applied to [cctools-port](https://github.com/tpoechtrager/cctools-port) branch `877.8-ld64-253.9-ppc` at f014422 (0004, 0008-0010 always; 0012 and 0015 when the toolchain runs on PowerPC Darwin) |
| `leopard-compat/leopard-compat.h` | what Leopard's libc lacks, force-included when cctools is built to run on 10.5 (also included by `toolchain/leopard-compat.h`) |

## The patches

GCC (GNU GPL 3 or later, like GCC):

| Patch | What |
|---|---|
| 0005 | `-fapple-kext` selects Apple's kext vtable layout (one virtual destructor slot) |
| 0006 | `std::source_location` objects get linker-visible labels, so ld64 does not fold them into a neighbour |
| 0007 | Darwin honours `-fno-reorder-functions` (keeps `main` in `__text` within branch range of crt1) |
| 0011 | `-mcpu=e6500` in 32-bit code is a 7450-class target, as Mac OS X reports the e6500 |
| 0101 | darwin64 ABI: small records passed on the stack are read where they were stored |
| 0102 | Darwin: GPR/FPR saves inline instead of out-of-line routines unless optimising for size |

cctools / ld64 (Apple Public Source Licence 2.0, like cctools):

| Patch | What |
|---|---|
| 0004 | ld64 emits 16-bit PowerPC section-difference relocations |
| 0008 | ld64 folds GCC's `__text_*` subsections into `__text` (branch islands work across them) |
| 0009 | ld64 PowerPC branch islands keep the target's offset |
| 0010 | the assembler knows Power ISA 2.06 and the e6500's Book-E instructions |
| 0012 | cctools-port builds on a PowerPC Darwin host |
| 0015 | ld64 writes its output with write(2) instead of a shared mapping (for kernels whose MAP_SHARED writeback is unreliable) |

Checked on 2026-11-11: a toolchain built by `build-toolchain.sh` on Linux
x86_64, packed by `make-toolchain-tarball.sh` and installed elsewhere compiles
C++ to assembly identical to the toolchain FrostByte was developed with.
