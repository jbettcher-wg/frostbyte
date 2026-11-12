#!/usr/bin/env bash
# Build FrostByte: one command, from a fresh clone to FrostByte.app.
#
#   ./build.sh --sdk=<Xcode 3.1.4 .dmg | MacOSX10.5.pkg | MacOSX10.5.sdk>     the first time
#   ./build.sh                                                                 after that
#
# Stages, run in this order (name some to run only those):
#   check      host detection and build prerequisites
#   sdk        import and verify the Mac OS X 10.5 SDK (you supply it; Apple's licence)
#   toolchain  GCC 15.3 + cctools/ld64 for powerpc-apple-darwin9: prebuilt download, else source
#   fetch      download and verify WebKit and every dependency, unpack and patch WebKit
#   hosttools  meson, gperf, unifdef, GLib tools, ICU (programs the build runs on this machine)
#   deps       the libraries FrostByte ships (GLib, libsoup, GnuTLS, ICU, GStreamer, FFmpeg, ...)
#   webkit     WPE WebKit 2.54.1 with the Leopard/PowerPC port
#   shell      the FrostByte browser shell
#   app        a self-contained FrostByte.app (in build/dist/FrostByte-<target>/)
#   dmg        a disk image of the app (not run by default)
#
# Options:
#   --target=generic|g5|t4240   CPU profile (default generic: any G5 or e6500; see toolchain/target.sh)
#   --sdk=PATH                  the SDK source (see above); remembered after the first import
#   --toolchain=auto|prebuilt|source|DIR    where the compiler comes from (default auto)
#   --jobs=N                    parallel compile jobs (default: from memory, see tools/wpe-ninja.sh)
#   --configure-only            stop the webkit stage after CMake's configure
#   --dry-run                   print what would run
#   --dmg                       also make the disk image
#   --cache=DIR                 downloads, toolchains and the SDK (default ~/.cache/frostbyte)
#   --build-dir=DIR             build outputs (default ./build)
#
# Hosts: Linux (x86_64, arm64) and macOS (Intel, Apple Silicon) cross-build; Mac OS X 10.5 on a
# 64-bit PowerPC (a Power Mac G5, or an NXP T4240 system) builds natively. See README.md and
# docs/building.md.
set -euo pipefail
cd "$(dirname "$0")"
FB_ROOT=$(pwd)
STAGES_ALL="check sdk toolchain fetch hosttools deps webkit shell app"
stages=() sdk_arg= tc_mode= cfg_only=0 want_dmg=0
# "--opt value" is accepted as well as "--opt=value".
args=()
while [ $# -gt 0 ]; do
    case "$1" in
    --target|--sdk|--toolchain|--jobs|--cache|--build-dir)
        [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }
        args+=("$1=$2"); shift 2 ;;
    *) args+=("$1"); shift ;;
    esac
done
for a in "${args[@]+"${args[@]}"}"; do
    case "$a" in
    --target=*) export LEOPARD_TARGET=${a#*=} ;;
    --sdk=*) sdk_arg=${a#*=} ;;
    --toolchain=*) tc_mode=${a#*=} ;;
    --jobs=*) export FB_JOBS=${a#*=} ;;
    --configure-only) cfg_only=1 ;;
    --dry-run) export FB_DRY_RUN=1 ;;
    --dmg) want_dmg=1 ;;
    --cache=*) export FROSTBYTE_CACHE=${a#*=} ;;
    --build-dir=*) export LEOPARD_BUILD=${a#*=} ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    -*) echo "unknown option $a (see ./build.sh --help)" >&2; exit 2 ;;
    *) case " $STAGES_ALL dmg " in *" $a "*) stages+=("$a") ;; *) echo "unknown stage $a (see ./build.sh --help)" >&2; exit 2 ;; esac ;;
    esac
done
[ "${#stages[@]}" -gt 0 ] || { read -r -a stages <<< "$STAGES_ALL"; [ "$want_dmg" = 1 ] && stages+=(dmg); }
export LEOPARD_TARGET="${LEOPARD_TARGET:-generic}"
case "$LEOPARD_TARGET" in generic|g5|t4240) ;; *) echo "--target must be generic, g5 or t4240" >&2; exit 2 ;; esac
. scripts/lib.sh
. scripts/host.sh
fb_detect_host
export LEOPARD_ROOT="$FB_ROOT"

say "FrostByte build: target $LEOPARD_TARGET on $FB_HOST_DESC"
note "cache $FROSTBYTE_CACHE, build $LEOPARD_BUILD; stages: ${stages[*]}"

for s in "${stages[@]}"; do
    case "$s" in
    check)
        chk=()
        [ "$tc_mode" = source ] && chk+=(--toolchain-source)
        case "$sdk_arg" in *.dmg) chk+=(--sdk-dmg) ;; esac
        scripts/stage-check.sh "${chk[@]+"${chk[@]}"}" ;;
    sdk)       scripts/stage-sdk.sh ${sdk_arg:+"$sdk_arg"} ;;
    toolchain) scripts/stage-toolchain.sh ${tc_mode:+"$tc_mode"} ;;
    fetch)     scripts/stage-fetch.sh wpe deps host ;;
    hosttools) scripts/stage-hosttools.sh ;;
    deps)      scripts/stage-deps.sh ;;
    webkit)    if [ "$cfg_only" = 1 ]; then scripts/stage-webkit.sh --configure-only; else scripts/stage-webkit.sh; fi ;;
    shell)     scripts/stage-package.sh shell ;;
    app)       scripts/stage-package.sh app ;;
    dmg)       scripts/stage-package.sh dmg ;;
    esac
    [ "$cfg_only" = 1 ] && [ "$s" = webkit ] && { ok "stopped after WebKit's configure (--configure-only)"; exit 0; }
done
ok "done: ${stages[*]}"
