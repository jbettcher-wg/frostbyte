# Build profile: LEOPARD_TARGET=t4240|g5|generic switches everything target-specific.
#   . toolchain/target.sh        (wpe-env.sh sources it; so do the deps, WebKit and FrostByte builds)
#
#   t4240    NXP T4240 systems (e6500 cores): -mcpu=e6500, the ISA 2.06 JIT (isel,
#            popcntw/popcntd, ldbrx/stdbrx, lbarx/lharx).
#   g5       Apple Power Mac G5 (PowerPC 970/970FX/970MP) on stock Mac OS X 10.5.8: -mcpu=970
#            (AltiVec; hardware fsqrt), the JIT without ISA 2.06 forms.
#   generic  any 64-bit AltiVec PowerPC that runs 10.5 ppc64 (G5 and e6500): the 970 ISA without
#            fsqrt/fsqrts (the e6500 traps on them), generic tuning, the JIT without ISA 2.06 forms.
#
# Each non-default target gets its own stage, build directories and FrostByte output, so the
# T4240 build is never touched by a G5 build.
LEOPARD_TARGET="${LEOPARD_TARGET:-generic}"
case "$LEOPARD_TARGET" in
t4240)
    LEOPARD_CPU_FLAGS="-mcpu=e6500"
    LEOPARD_MESON_CPU=e6500
    LEOPARD_FFMPEG_CPU=e6500
    LEOPARD_SUFFIX=""
    LEOPARD_JIT_ISA206=1 ;;
g5)
    LEOPARD_CPU_FLAGS="-mcpu=970"
    LEOPARD_MESON_CPU=970
    LEOPARD_FFMPEG_CPU=970
    LEOPARD_SUFFIX="-g5"
    LEOPARD_JIT_ISA206=0 ;;
generic)
    LEOPARD_CPU_FLAGS="-mcpu=970 -mno-powerpc-gpopt -mtune=powerpc64"
    LEOPARD_MESON_CPU=ppc64
    LEOPARD_FFMPEG_CPU=970
    LEOPARD_SUFFIX="-generic"
    LEOPARD_JIT_ISA206=0 ;;
*)
    echo "LEOPARD_TARGET must be t4240, g5 or generic (got '$LEOPARD_TARGET')" >&2
    return 2 2>/dev/null || exit 2 ;;
esac
export LEOPARD_TARGET LEOPARD_CPU_FLAGS LEOPARD_MESON_CPU LEOPARD_FFMPEG_CPU LEOPARD_SUFFIX LEOPARD_JIT_ISA206
