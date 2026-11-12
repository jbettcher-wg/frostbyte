#!/bin/sh
# Configure WPE WebKit 2.54.1 (+ Leopard JSC port) for FrostByte, ppc64 Mac OS X 10.5.
#   [WPE_SRC_DIR=<src>] [WPE_BUILD_DIR=<dir>] toolchain/configure-wpe.sh [extra cmake args]   (default build/wpe-254)
# Tier "soft" first: no WebGL/GL compositing requirement, no GStreamer, no Linux graphics stack.
# JS tiers: LLInt + Baseline + DFG + FTL (2026-11-09: the FTL is correct on BE after the B3 spill-slot fixes, all
# 13 Octane benchmarks and the test suites pass, +38% geomean over DFG; JSC_useFTLJIT=0 turns it off at run time).
set -e
S="$(cd "$(dirname "$0")/.." && pwd)"
. "$S/toolchain/wpe-env.sh"
SRC="${WPE_SRC_DIR:-$LEOPARD_BUILD/src/wpewebkit-2.54.1}"
# LEOPARD_TARGET (toolchain/target.sh, via wpe-env.sh): t4240 -> build/wpe-254, g5 -> build/wpe-254-g5, ...
B="${WPE_BUILD_DIR:-$LEOPARD_BUILD/wpe-254$LEOPARD_SUFFIX}"
# Non-default targets are packaged as a self-contained FrostByte.app (tools/package-app.py), whose
# install-name rewrite needs header room in every WebKit image.
TARGET_LDFLAGS=""
[ "$LEOPARD_TARGET" = t4240 ] || TARGET_LDFLAGS=" -Wl,-headerpad_max_install_names"
export PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
# Media backend (build option): LEOPARD_MEDIA=gstreamer (default; GStreamer from deps/, README 21, software
# decode, Web Audio on) or elements (<video>/<audio> without a backend, nothing plays).
case "${LEOPARD_MEDIA:-gstreamer}" in
  gstreamer) MEDIA_ARGS="-DUSE_GSTREAMER=ON -DLEOPARD_MEDIA_ELEMENTS_WITHOUT_BACKEND=OFF -DUSE_GSTREAMER_GL=OFF -DENABLE_WEB_AUDIO=ON -DENABLE_SPEECH_SYNTHESIS=OFF" ;;
  elements)  MEDIA_ARGS="-DUSE_GSTREAMER=OFF -DLEOPARD_MEDIA_ELEMENTS_WITHOUT_BACKEND=ON -DENABLE_WEB_AUDIO=OFF" ;;
  *) echo "LEOPARD_MEDIA must be gstreamer or elements" >&2; exit 2 ;;
esac
# Flags come from the CMake toolchain file; wpe-env.sh's CFLAGS/LDFLAGS are for the deps.
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
export PATH="$LEOPARD_BUILD/host/bin:$PATH"   # host tools built from source (gperf)
# Shared libraries keep their static GCC 15 libstdc++ private: dyld coalesces weak C++ symbols
# across images, and Cocoa loads Leopard's own libstdc++ (std::string empty-rep clash; README 19.3).
exec cmake -S "$SRC" -B "$B" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$S/toolchain/darwin9-ppc64.cmake" -DLEOPARD_TARGET="$LEOPARD_TARGET" \
  -DPORT=WPE -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$WPE_PREFIX \
  -DGLIB_COMPILE_RESOURCES_EXECUTABLE="$LEOPARD_BUILD/host/bin/glib-compile-resources" \
  -DLEOPARD_WPE_SYSROOT="$WPE_SYSROOT" -DICU_ROOT="$WPE_SYSROOT" \
  -DCMAKE_EXE_LINKER_FLAGS="-m64 -static-libgcc -static-libstdc++ -L$WPE_SYSROOT/lib$TARGET_LDFLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="-m64 -static-libgcc -static-libstdc++ -L$WPE_SYSROOT/lib -Wl,-unexported_symbols_list,$S/toolchain/hide-libstdcxx.exp$TARGET_LDFLAGS" \
  -DCMAKE_MODULE_LINKER_FLAGS="-m64 -static-libgcc -static-libstdc++ -L$WPE_SYSROOT/lib -Wl,-unexported_symbols_list,$S/toolchain/hide-libstdcxx.exp$TARGET_LDFLAGS" \
  -DDEVELOPER_MODE=OFF -DDEVELOPER_MODE_FATAL_WARNINGS=OFF \
  `# Little-endian typed-array element storage (all targets): the web assumes an LE host` \
  `# (Emscripten/Mandreel heaps, binary parsers); JSC byte-swaps typed-array loads/stores.` \
  -DLEOPARD_LE_TYPED_ARRAYS=ON \
  -DENABLE_JIT=ON -DENABLE_C_LOOP=OFF -DENABLE_DFG_JIT=ON -DENABLE_FTL_JIT=ON -DENABLE_WEBASSEMBLY_BBQJIT=ON -DENABLE_WEBASSEMBLY_OMGJIT=OFF \
  -DENABLE_WEBASSEMBLY=ON -DENABLE_SAMPLING_PROFILER=OFF \
  -DUSE_SYSTEM_MALLOC=OFF -DUSE_MIMALLOC=ON \
  -DMig_EXECUTABLE="$S/toolchain/mig-stub.sh" -DUSE_CXX_STDLIB_ASSERTIONS=OFF -DENABLE_API_TESTS=OFF \
  -DENABLE_WPE_PLATFORM=ON -DENABLE_WPE_PLATFORM_HEADLESS=ON \
  -DENABLE_WPE_PLATFORM_DRM=OFF -DENABLE_WPE_PLATFORM_WAYLAND=OFF -DENABLE_WPE_LEGACY_API=OFF \
  -DENABLE_WPE_QT_API=OFF -DENABLE_COG=OFF -DENABLE_MINIBROWSER=OFF -DENABLE_WEBDRIVER=OFF \
  -DUSE_GBM=OFF -DUSE_LIBDRM=OFF -DUSE_VULKAN=OFF -DENABLE_WEBGL=OFF \
  `# Media elements (HTMLVideoElement, Audio, MediaSource) exist with no backend yet: pages that touch them` \
  `# work, nothing plays. A GStreamer backend (later UVD) plugs in with -DUSE_GSTREAMER=ON.` \
  $MEDIA_ARGS -DENABLE_WEB_CODECS=OFF -DENABLE_VIDEO=ON -DENABLE_MEDIA_SOURCE=ON -DENABLE_MEDIA_STREAM=OFF -DENABLE_WEB_RTC=OFF -DENABLE_ENCRYPTED_MEDIA=OFF \
  -DENABLE_GAMEPAD=OFF -DENABLE_SPEECH_SYNTHESIS=OFF -DUSE_FLITE=OFF -DUSE_SPIEL=OFF \
  -DENABLE_DOCUMENTATION=OFF -DENABLE_INTROSPECTION=OFF -DENABLE_JOURNALD_LOG=OFF \
  -DENABLE_BUBBLEWRAP_SANDBOX=OFF -DUSE_SYSPROF_CAPTURE=OFF -DUSE_LIBBACKTRACE=OFF \
  -DUSE_ATK=OFF -DUSE_LIBHYPHEN=OFF -DENABLE_SPELLCHECK=OFF -DENABLE_XSLT=OFF \
  -DUSE_SYSTEM_UNIFDEF=ON -DUNIFDEF_EXECUTABLE="$LEOPARD_BUILD/host/bin/unifdef" -DUSE_AVIF=OFF -DUSE_LCMS=OFF -DUSE_JPEGXL=OFF -DUSE_WOFF2=OFF \
  "$@"
