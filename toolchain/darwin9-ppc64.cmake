# CMake toolchain file: cross-build for Mac OS X 10.5 on 64-bit big-endian
# PowerPC (Darwin ppc64 ABI).
#
# CMAKE_SYSTEM_PROCESSOR=powerpc64 so WebKitCommon.cmake selects
# WTF_CPU_PPC64 (64-bit big-endian) rather than PPC or PPC64LE.
#
#   cmake -S <src> -B <build> -G Ninja -DCMAKE_TOOLCHAIN_FILE=$PWD/toolchain/darwin9-ppc64.cmake ...
#
# Binaries it links still need the ld64 LC_UNIXTHREAD srr0 fixup before they
# run on Mac OS X 10.5; run tools/fix-ppc64-entry.py
# over every executable.
# The toolchain and SDK: ./build.sh records them in build/toolchain.env and toolchain/wpe-env.sh
# exports them; -DLEOPARD_TOOLCHAIN=/-DLEOPARD_SDK= on the command line work too.
if (NOT LEOPARD_TOOLCHAIN)
    set(LEOPARD_TOOLCHAIN "$ENV{LEOPARD_TOOLCHAIN}" CACHE PATH "powerpc-apple-darwin9 toolchain prefix")
endif ()
if (NOT LEOPARD_SDK)
    set(LEOPARD_SDK "$ENV{LEOPARD_SDK}" CACHE PATH "Mac OS X 10.5 SDK")
endif ()
if (NOT EXISTS "${LEOPARD_TOOLCHAIN}/bin/powerpc-apple-darwin9-gcc")
    message(FATAL_ERROR "LEOPARD_TOOLCHAIN (${LEOPARD_TOOLCHAIN}) has no powerpc-apple-darwin9-gcc: run ./build.sh toolchain")
endif ()
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES LEOPARD_TOOLCHAIN LEOPARD_SDK)
set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_SYSTEM_VERSION 9.8.0)
set(CMAKE_SYSTEM_PROCESSOR powerpc64)
set(CMAKE_C_COMPILER   ${LEOPARD_TOOLCHAIN}/bin/powerpc-apple-darwin9-gcc)
set(CMAKE_CXX_COMPILER ${LEOPARD_TOOLCHAIN}/bin/powerpc-apple-darwin9-g++)
set(CMAKE_AR                ${LEOPARD_TOOLCHAIN}/bin/powerpc-apple-darwin9-ar)
set(CMAKE_RANLIB            ${LEOPARD_TOOLCHAIN}/bin/powerpc-apple-darwin9-ranlib)
set(CMAKE_INSTALL_NAME_TOOL ${LEOPARD_TOOLCHAIN}/bin/powerpc-apple-darwin9-install_name_tool)
set(CMAKE_OTOOL             ${LEOPARD_TOOLCHAIN}/bin/powerpc-apple-darwin9-otool)
set(CMAKE_NM                ${LEOPARD_TOOLCHAIN}/bin/powerpc-apple-darwin9-nm)
set(CMAKE_STRIP             ${LEOPARD_TOOLCHAIN}/bin/powerpc-apple-darwin9-strip)
# The compiler carries its own sysroot (the 10.5 SDK); stop CMake adding
# -isysroot/-arch/-mmacosx-version-min of its own.
set(CMAKE_OSX_SYSROOT "" CACHE STRING "")
set(CMAKE_OSX_ARCHITECTURES "" CACHE STRING "")
set(CMAKE_OSX_DEPLOYMENT_TARGET "" CACHE STRING "")
set(LEOPARD_COMPAT ${CMAKE_CURRENT_LIST_DIR}/leopard-compat.h)
# DARWIN9 is the switch the WebKit CMake files and WTF's Platform*.h consult
# for "Darwin, but Leopard: no Cocoa sources, no libdispatch, no Mach
# exceptions, GCC". The CMake variable and the preprocessor macro are the
# same switch; keep them together.
set(DARWIN9 ON CACHE BOOL "Target is Mac OS X 10.5 (Darwin 9) without Cocoa-era APIs")
# Build profile (toolchain/target.sh): -DLEOPARD_TARGET=generic (default) | g5 | generic.
# t4240 keeps exactly the flags it always had. g5/generic target the PowerPC 970 ISA and tell
# the JIT (PPC64Assembler.h) that isel, popcntw/popcntd, ldbrx/stdbrx and lbarx/lharx are absent.
set(LEOPARD_TARGET "generic" CACHE STRING "Build profile: t4240, g5 or generic")
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES LEOPARD_TARGET)
if (LEOPARD_TARGET STREQUAL "t4240")
    set(LEOPARD_CPU_FLAGS "-mcpu=e6500")
elseif (LEOPARD_TARGET STREQUAL "g5")
    set(LEOPARD_CPU_FLAGS "-mcpu=970 -DLEOPARD_PPC64_ISA206=0")
elseif (LEOPARD_TARGET STREQUAL "generic")
    set(LEOPARD_CPU_FLAGS "-mcpu=970 -mno-powerpc-gpopt -mtune=powerpc64 -DLEOPARD_PPC64_ISA206=0")
else ()
    message(FATAL_ERROR "LEOPARD_TARGET must be t4240, g5 or generic")
endif ()
# toolchain/include holds shim headers for things 10.5 lacks (mach/vm_page_size.h).
set(CMAKE_C_FLAGS_INIT   "-m64 ${LEOPARD_CPU_FLAGS} -DWTF_DARWIN9=1 -DSIMDUTF_IMPLEMENTATION_PPC64=0 -D_DARWIN_USE_64_BIT_INODE=1 -isystem ${CMAKE_CURRENT_LIST_DIR}/include -include ${LEOPARD_COMPAT}")
set(CMAKE_CXX_FLAGS_INIT "-m64 ${LEOPARD_CPU_FLAGS} -DWTF_DARWIN9=1 -DSIMDUTF_IMPLEMENTATION_PPC64=0 -D_DARWIN_USE_64_BIT_INODE=1 -isystem ${CMAKE_CURRENT_LIST_DIR}/include -include ${LEOPARD_COMPAT}")
# Static libgcc/libstdc++: the cross GCC's shared ones carry this host's path as
# their install name, so a dynamically linked binary dies in dyld on Mac OS X 10.5
# (measured: "Library not loaded: .../toolchain-user64-gcc15p/.../libgcc_s.1.1.dylib").
set(CMAKE_EXE_LINKER_FLAGS_INIT    "-m64 -static-libgcc -static-libstdc++")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-m64 -static-libgcc -static-libstdc++")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-m64 -static-libgcc -static-libstdc++")
# Find libraries and headers in the 10.5 SDK and our own staging prefix only.
# JSC-only builds search prefix-ppc64 (static ICU). WPE/FrostByte builds pass
# -DLEOPARD_WPE_SYSROOT=<stage-wpe/opt/wpe> and search that prefix instead.
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES LEOPARD_WPE_SYSROOT)
if (DEFINED LEOPARD_WPE_SYSROOT)
    set(LEOPARD_PREFIX ${LEOPARD_WPE_SYSROOT})
else ()
    set(LEOPARD_PREFIX ${CMAKE_CURRENT_LIST_DIR}/../prefix-ppc64)
endif ()
set(CMAKE_FIND_ROOT_PATH ${LEOPARD_PREFIX} ${LEOPARD_SDK})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_PREFIX_PATH ${LEOPARD_PREFIX})
