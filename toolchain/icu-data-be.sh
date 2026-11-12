#!/bin/sh
# Make ICU's data genuinely big-endian: writes $LEOPARD_BUILD/icu-data-be/icudt77b_dat.o, which
# deps/build-deps.sh (pkg_icu) links into libicudata.77.dylib.
#
# ICU's cross build produced data/out/tmp/icudt77b.dat NAMED big-endian but with the build
# host's little-endian bytes (header byte 8, isBigEndian, was 0), and genccode then wrote those
# bytes as host-order 32-bit words, so the data in the linked library was byte-swapped per word.
# Every data-driven ICU service (collation, number/date formatting, plural rules) failed on
# Mac OS X while the compiled-in tables (case mapping, normalisation) worked. Measured 2026-11-07.
#
# This converts the archive with the host icupkg (built by ./build.sh hosttools) and emits it as
# big-endian words, which the Darwin assembler stores big-endian, so the byte stream is preserved.
#   toolchain/icu-data-be.sh [<icudt77b.dat>]   default: data/out/tmp/icudt77b.dat under the
#                                                current directory (pkg_icu runs it from ICU's build)
set -e
S="$(cd "$(dirname "$0")/.." && pwd)"
. "$S/toolchain/wpe-env.sh"
H="$LEOPARD_BUILD/icu-host"
D="$LEOPARD_BUILD/icu-data-be"
SRC="${1:-${ICU_DAT:-$PWD/data/out/tmp/icudt77b.dat}}"
[ -f "$SRC" ] || { echo "icu-data-be.sh: no $SRC (run it from ICU's build directory or pass the .dat)" >&2; exit 1; }
mkdir -p "$D"; cd "$D"
LD_LIBRARY_PATH="$H/lib" DYLD_LIBRARY_PATH="$H/lib" "$H/bin/icupkg" -tb "$SRC" icudt77b.dat
python3 -I - <<'PY'
import struct
d=open('icudt77b.dat','rb').read(); d+=b'\0'*((-len(d))%16)
assert d[8]==1, 'archive is not big-endian after icupkg -tb'
with open('icudt77b_dat.S','w') as out:
    out.write("\t.globl _icudt77_dat\n\t.const_data\n\t.p2align 4\n_icudt77_dat:\n")
    w=struct.unpack('>%dI' % (len(d)//4), d)
    for i in range(0,len(w),8):
        out.write('\t.long ' + ','.join('0x%x' % x for x in w[i:i+8]) + '\n')
PY
${CC% *} -m64 -c -o icudt77b_dat.o icudt77b_dat.S
echo "big-endian ICU data object: $D/icudt77b_dat.o"
