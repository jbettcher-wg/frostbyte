#ifndef LEOPARD_COMPAT_TOOLCHAIN_H
#define LEOPARD_COMPAT_TOOLCHAIN_H
/* Before any system header: Leopard's <inttypes.h> only defines PRIx64 etc. for C++ when asked. */
#ifndef __STDC_FORMAT_MACROS
#define __STDC_FORMAT_MACROS 1
#endif
/* Khronos <EGL/eglplatform.h> has an __APPLE__ branch (EGLNativeDisplayType = int); WPE passes pointers.
 * ABI-neutral on ppc64 (both GPR-passed); LeopardEGL and libepoxy treat native handles as opaque. */
#ifndef EGL_NO_PLATFORM_SPECIFIC_TYPES
#define EGL_NO_PLATFORM_SPECIFIC_TYPES 1
#endif
/* Force-included (-include) into every C/C++ compile of the Leopard ppc64
 * cross build. Wraps the kernel project's leopard-compat.h so that it is NOT
 * seen by assembler inputs: ICU's pkgdata compiles its generated .S data file
 * with CFLAGS, and the C in the header then reaches `as` ("Invalid mnemonic
 * 'unsigned'", measured). Anything this port needs beyond the kernel
 * project's shim goes below the include, not in their file. */
#ifndef LEOPARD_WEBKIT_COMPAT_H
#define LEOPARD_WEBKIT_COMPAT_H
#ifndef __ASSEMBLER__
#include "darwin-cross/leopard-compat/leopard-compat.h"
#endif
#endif

/* ---- additions for the WebKit port (C and C++), measured against bmalloc ---- */
#ifndef __ASSEMBLER__
#include <sys/mman.h>
/* madvise(2) reusable-page advice is 10.6+. MADV_FREE is the 10.5 behaviour
 * bmalloc/WTF want from MADV_FREE_REUSABLE; MADV_FREE_REUSE (re-commit) is a
 * no-op on a kernel that never counted the pages as reusable. */
#ifndef MADV_FREE_REUSABLE
#define MADV_FREE_REUSABLE MADV_FREE
#endif
#ifndef MADV_FREE_REUSE
#define MADV_FREE_REUSE MADV_FREE
#endif
/* <pthread/qos.h> is 10.10+. bmalloc and WTF only pass these through to
 * pthread_set_qos_class_self_np, which has nothing to act on here. */
#ifndef __QOS_ENUM
typedef unsigned int qos_class_t;
enum { QOS_CLASS_USER_INTERACTIVE = 0x21, QOS_CLASS_USER_INITIATED = 0x19, QOS_CLASS_DEFAULT = 0x15, QOS_CLASS_UTILITY = 0x11, QOS_CLASS_BACKGROUND = 0x09, QOS_CLASS_UNSPECIFIED = 0x00 };
static inline int pthread_set_qos_class_self_np(qos_class_t c, int p) { (void)c; (void)p; return 0; }
#define __QOS_ENUM 1
#endif
#endif /* __ASSEMBLER__ */

/* ---- additions measured against WTF (WebKitGTK 2.54.1) ---- */
#ifndef __ASSEMBLER__
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <mach/mach_time.h>
/* memmem(3) is 10.7+. */
static inline void* leopard_memmem(const void* h, size_t hl, const void* n, size_t nl)
{
	const char* hp = (const char*)h;
	if (nl == 0) return (void*)hp;
	if (hl < nl) return 0;
	for (size_t i = 0; i + nl <= hl; i++)
		if (hp[i] == *(const char*)n && memcmp(hp + i, n, nl) == 0) return (void*)(hp + i);
	return 0;
}
#define memmem leopard_memmem
/* MAP_JIT is 10.14+; this kernel grants PROT_EXEC on plain anonymous maps
 * so the flag is simply absent. */
#ifndef MAP_JIT
#define MAP_JIT 0
#endif
/* O_CLOEXEC is 10.7+. The 10.5 kernel ignores the bit, so callers that rely
 * on it get a descriptor without close-on-exec; jsc does not exec anything. */
#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
/* mkostemp(3) is 10.7+. */
static inline int leopard_mkostemp(char* tmpl, int flags)
{
	int fd = mkstemp(tmpl);
	if (fd >= 0 && (flags & FD_CLOEXEC)) fcntl(fd, F_SETFD, FD_CLOEXEC);
	return fd;
}
#define mkostemp leopard_mkostemp
/* mach_approximate_time (10.10) and mach_continuous_time (10.12): the e6500 port has
 * no sleep states and no cheaper clock, so all three are mach_absolute_time. */
static inline uint64_t mach_approximate_time(void) { return mach_absolute_time(); }
static inline uint64_t mach_continuous_time(void) { return mach_absolute_time(); }
static inline uint64_t mach_continuous_approximate_time(void) { return mach_absolute_time(); }
#endif /* __ASSEMBLER__ */

/* ---- additions measured against JavaScriptCore (WebKitGTK 2.54.1) ---- */
#ifndef __ASSEMBLER__
#include <pthread.h>
#include <uuid/uuid.h>
/* pthread_threadid_np is 10.6+; the Mach thread port is a stable per-thread id. */
static inline int leopard_pthread_threadid_np(pthread_t thread, uint64_t* tid)
{
	if (!tid) return 22; /* EINVAL */
	*tid = (uint64_t)pthread_mach_thread_np(thread ? thread : pthread_self());
	return 0;
}
#define pthread_threadid_np leopard_pthread_threadid_np
/* uuid_string_t is 10.6+. */
typedef char uuid_string_t[37];
#endif /* __ASSEMBLER__ */

/* ---- 10.5 SDK bug: LP64 CMSG_* (fd passing) ---- */
/* The SDK pads a 64-bit program's cmsghdr to 16 bytes; Leopard's kernel and the 10.6+ headers use
 * the packed 12-byte layout. Including <sys/socket.h> here first means every later include of it is
 * a no-op and the 10.6 macros from leopard-cmsg.h stay in force, whatever a source includes. */
#ifndef __ASSEMBLER__
#include <sys/socket.h>
#include "leopard-cmsg.h"
#endif

/* GCC 15.3 powerpc-apple-darwin9 -m64 ICE workaround switch, consulted by
 * WTF's time classes (MonotonicTime.h and friends, CurrentTime.cpp). */
#if defined(__GNUC__) && !defined(__clang__) && defined(__ppc64__)
#define WTF_DARWIN9_GCC_STRUCT_RETURN_WORKAROUND 1
#endif
#endif /* LEOPARD_COMPAT_TOOLCHAIN_H */
