# Building FrostByte: what happens, where it goes

`./build.sh` runs these stages in order. Each one is safe to re-run and skips work
that is already done.

| Stage | What it does | Prebuilt or built here |
|---|---|---|
| `check` | detects the host (cross or native), checks the build tools | — |
| `sdk` | imports the Mac OS X 10.5 SDK you supply and checks its digest | yours (Apple's licence) |
| `toolchain` | GCC 15.3 + cctools 877.8/ld64 253.9 for `powerpc-apple-darwin9` | **prebuilt tarball by default**, built from source as the fallback |
| `fetch` | downloads WebKit and every dependency, verifies SHA-256, unpacks WebKit and applies `patches/` | downloaded |
| `hosttools` | meson, gperf, unifdef, GLib's tools, a host ICU (programs the build runs) | built here |
| `deps` | the ~40 packages FrostByte ships (GLib, libsoup, GnuTLS, ICU, HarfBuzz, GStreamer, FFmpeg, ...) | built here |
| `webkit` | WPE WebKit 2.54.1 with the Leopard/PowerPC port | built here |
| `shell` | the FrostByte shell | built here |
| `app` | FrostByte.app with everything inside (`tools/package-app.py`), licence texts included, then checked (`tools/check-bundle.py`: thin ppc64, load commands against the SDK, entry points, and for g5/generic an instruction scan with llvm-objdump) | built here |
| `dmg` | a disk image of the app (only with `--dmg`) | built here |

Nothing FrostByte ships is downloaded prebuilt: only the compiler is, and only
because building it takes a while.

## Where things are kept

| What | Where | Override |
|---|---|---|
| verified downloads | `~/.cache/frostbyte/dl/<category>/` | `FROSTBYTE_CACHE` or `--cache=` (whole cache), `LEOPARD_DL` |
| the imported SDK | `~/.cache/frostbyte/sdk/MacOSX10.5.sdk` | |
| installed toolchains | `~/.cache/frostbyte/toolchains/<id>-<host>/` | `--toolchain=<dir>` |
| everything built | `build/` in the checkout | `LEOPARD_BUILD` or `--build-dir=` |
| the WebKit source tree | `build/src/wpewebkit-2.54.1` (tarball + patches) | |
| host tools | `build/host/` | |
| a target's libraries | `build/stage-wpe-<target>/opt/wpe` | |
| a target's WebKit build | `build/wpe-254-<target>/` | `WPE_BUILD_DIR` |
| the app | `build/dist/FrostByte-<target>/FrostByte.app` | |
| what the toolchain/sdk stages chose | `build/toolchain.env` | `LEOPARD_TOOLCHAIN`, `LEOPARD_SDK` |

The cache is shared by every checkout. Deleting `build/` starts a build over
without downloading anything again; deleting the cache forgets the downloads,
the SDK and the toolchain. Disk: about 10 GB per target in `build/`, 0.3 GB of
downloads, 0.35 GB per toolchain (6 GB more while one builds from source).

To package a stage and shell built in another directory, set
`FB_STAGE_DIR=<stage-wpe dir>` and `FB_SHELL_BIN=<frostbyte-shell>` for the
webkit/app stages.

`LEOPARD_WEBGL=OFF` builds without WebGL (WebKit without ANGLE, LeopardEGL
without its WebGL paths: the 0.3.x configuration); the default is `ON`. Either
way WebGL is off at run time until it is turned on in Preferences > Hardware.

`FB_OFFLINE=1` makes the fetch stage fail instead of downloading;
`FB_DL_SEED=<dir>` lets it pick up already-downloaded archives from a directory
(they are still checksummed); `FB_MIRROR=<url>` is tried before the upstream URLs.

## Memory and parallel jobs

WebKit's unified sources need 2-4 GB of memory per compile job, so the job count
follows memory rather than cores: `min(cores, 0.576 x RAM / 3 GB, 30)`. On Linux
with systemd the build also runs in a user scope with `MemoryHigh` = 0.576 x RAM,
`MemoryMax` = 0.64 x RAM and no swap, so a build that outgrows memory is
throttled and then stopped instead of taking the desktop down. Override with
`--jobs=N` (or `FB_JOBS`), `FB_MEM_HIGH=72G`, `FB_MEM_MAX=80G`; `FB_NO_SCOPE=1`
turns the scope off. Every ninja run on WebKit goes through `tools/wpe-ninja.sh`,
which applies these.

## The toolchain

FrostByte is compiled by FSF GCC 15.3.0 (C, C++, Objective-C; ppc and ppc64
multilib) with Apple's cctools 877.8 and ld64 253.9 (from
[cctools-port](https://github.com/tpoechtrager/cctools-port)), all targeting
`powerpc-apple-darwin9`, plus patches:

- `toolchain/darwin-cross/patches/gcc/`: Darwin ABI and code-generation fixes
  (the darwin64 small-record ABI, inline GPR/FPR saves, source_location labels,
  `-fno-reorder-functions`, e6500 as a 7450-class CPU, the `-fapple-kext` vtable);
- `toolchain/darwin-cross/patches/cctools/`: ld64's PowerPC relocations and
  branch islands, the assembler's Power ISA 2.06 and e6500 mnemonics, and (for a
  toolchain that runs on Leopard) building on a PowerPC Darwin host and writing
  output without `mmap`.

`toolchain/darwin-cross/README.md` lists them. The toolchain is one prefix with the SDK linked in as its sysroot
(`<toolchain>/sdk`), so it can live anywhere.

`--toolchain=` chooses where it comes from:

- `auto` (default): an installed toolchain if there is one; otherwise the
  prebuilt tarball for this host if one is published in
  `config/toolchain.lock` (today: Linux x86_64, attached to the v0.3 release;
  it needs glibc 2.38 or newer, and on an older system the build falls back to
  source); otherwise build from source.
- `prebuilt`: download and install the tarball. `FB_TOOLCHAIN_TARBALL=<file>`
  installs a local one (checked against `<file>.sha256` when present).
- `source`: `toolchain/darwin-cross/build-toolchain.sh`. Measured: 6.5 minutes on
  a 56-core EPYC (Linux, `-j20`); expect 30-60 minutes on a laptop.
- `<dir>`: an existing toolchain (`<dir>/bin/powerpc-apple-darwin9-gcc` etc.).

Every toolchain is smoke-tested before use (C, C++ and Objective-C, ppc and
ppc64, linked against the SDK, `ld` is ld64-253.9).

A compiler split across two prefixes (GCC in one, cctools in another) can be
used as is:
`FB_TOOLCHAIN_GCC=<gcc prefix> FB_TOOLCHAIN_CCTOOLS=<cctools prefix> ./build.sh toolchain`.

### What the prebuilt tarball holds, and what it does not

The tarball is the installed toolchain minus everything that comes from Apple's
SDK: no `sdk` link, and an empty `include-fixed` (GCC's fixincludes copies of
SDK headers). Installing it links your SDK in and regenerates `include-fixed`
with GCC's own `mkheaders`. `make-toolchain-tarball.sh` refuses to finish if any
file in the tarball is identical to a file in the SDK (apart from GCC's own
`varargs.h` and include README, which Apple's SDK also carries).

Checked on Linux x86_64: a toolchain built from source, packed, installed into a
different directory and smoke-tested produces assembly byte-identical to the
toolchain FrostByte was developed with (48k lines of C++ at `-mcpu=e6500` and
`-mcpu=970`).

### Making the prebuilt tarballs

The SDK must be imported first (`./build.sh sdk --sdk=...`).

```sh
# On each kind of build host (a Linux x86_64 box, a Linux arm64 box, an Intel Mac,
# an Apple Silicon Mac), from a checkout:
toolchain/darwin-cross/make-toolchain-tarball.sh
#   -> build/dist/frostbyte-toolchain-<id>-<host>.tar.xz and .sha256,
#      and the line for config/toolchain.lock

# Or pack a toolchain that is already built:
toolchain/darwin-cross/make-toolchain-tarball.sh --from=<prefix>

# The toolchain that runs ON Mac OS X 10.5 PowerPC, made on Linux (a canadian build,
# with a finished cross toolchain doing the compiling):
toolchain/darwin-cross/make-toolchain-tarball.sh --host=darwin9-ppc64 \
    --build-toolchain=$HOME/.cache/frostbyte/toolchains/<id>-linux-x86_64
#   -> ...-darwin9-ppc64.tar.gz (gzip: Leopard's tar cannot read xz)
```

Then attach each file to a GitHub release, put its download URL and SHA-256 in
its line of `config/toolchain.lock` (replacing the `-`s), and commit. Nothing is uploaded by the scripts.
Build the Linux tarballs on an old distribution (a Debian 11 or AlmaLinux 8
container) so they run on any newer glibc. Bump the `id` in
`config/toolchain.lock` whenever the GCC or cctools sources or patches change.

The darwin9-ppc64 toolchain's programs are set up to find GCC's libstdc++
through `@loader_path`, so it should work from any directory. That build has not
been run yet (see "Building on a G5 or a T4240").

## Building on a G5 or a T4240 (native)

On Mac OS X 10.5 on a 64-bit PowerPC, `./build.sh` builds natively. It needs:

- **The SDK**: Xcode 3.1.4's `/Developer/SDKs/MacOSX10.5.sdk` is found
  automatically.
- **The toolchain**, found in this order: `/usr/local/frostbyte-toolchain`; the
  prebuilt `darwin9-ppc64` tarball (once published); a source build with
  `build-toolchain.sh --mode=native`, which needs a C++11 compiler on the Mac to
  start from (`FB_BOOTSTRAP_CC`/`FB_BOOTSTRAP_CXX`; MacPorts `gcc14` works) and
  takes hours. A plain `/usr/local/gcc-15` is only used
  if it has ppc64 libraries and you set `FB_ALLOW_UNPATCHED_GCC=1`, because it
  lacks the ABI patches.
- **Build tools from MacPorts**: Python 3.9+, Perl 5.10+, Ruby 2.5+ (10.5's own
  Perl 5.8.8 and Ruby 1.8.6 are too old), CMake 3.20+, Ninja, pkg-config, rsync,
  xz, shared-mime-info, libffi, pcre2. `./build.sh check` lists what is missing.

How long it takes (estimates, not measurements). The WebKit build is about 11
CPU-hours of compiling on a modern x86 core (measured from the ninja log of a
full build on the EPYC host); the dependencies add roughly 1-2 more.

| Machine | Per-core speed vs. a modern x86 core | Parallel jobs (memory-bound) | WebKit + deps |
|---|---|---|---|
| Linux/macOS, 16+ cores, 64+ GB | 1x | 16-30 | about 1 hour, plus the toolchain if built (10-60 min) |
| Power Mac G5 Quad (970MP 2.5 GHz, 4 cores, up to 16 GB) | ~1/8-1/10 | 3-4 | **1-2 days** |
| NXP T4240 (12 e6500 cores / 24 threads at 1.8 GHz, 48 GB) | ~1/15-1/20 per thread | ~12 | **about a day** |

The native compiler's own programs are 32-bit, so a single compile job can use at
most about 3.5 GB; the biggest WebCore units come close to that. If one fails
for lack of memory, build the toolchain with 64-bit programs
(`FB_CANADIAN_HOST_BITS=64` for the canadian build), or cross-build instead.
A native build on a machine you also use as a desktop will make it sluggish
for the whole time; `--jobs=` lowers the load.
