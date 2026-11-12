/*
 * What modern sources call that Mac OS X 10.5's libc does not have, for
 * programs built to RUN on Mac OS X 10.5 (build-toolchain.sh --mode=native/canadian).
 * Force-included with -include. Each entry is here because a build failed
 * without it; add the next one the same way, with the program that needed
 * it. See also the memory note on Leopard libc gaps (realpath(NULL),
 * clock_gettime, pipe2).
 */
#ifndef LEOPARD_COMPAT_H
#define LEOPARD_COMPAT_H
#include <stddef.h>
#include <AvailabilityMacros.h>

#if MAC_OS_X_VERSION_MIN_REQUIRED < 1070
/* strnlen: 10.7. Needed by cctools 877.8 otool (ofile_print.c). */
static inline size_t
leopard_strnlen(const char *s, size_t max)
{
	size_t n = 0;

	while (n < max && s[n] != '\0')
		n++;
	return n;
}
#define strnlen leopard_strnlen
#endif

/* __private_extern__ is an Apple-GCC storage class; FSF GCC targeting
 * Darwin does not know it. Same definition cctools-port uses on Linux
 * (include/foreign/extern.h). Needed by cctools 877.8 throughout. */
#ifndef __private_extern__
#define __private_extern__ __attribute__((visibility("hidden")))
#endif

/* OSAtomicAdd64: 10.5's libSystem has it for ppc64, i386 and x86_64 only
 * (<libkern/OSAtomic.h>:85). ld64 253.9 uses it for -print_statistics byte
 * counters (InputFiles.cpp), so C++ only: BlocksRuntime's runtime.c defines
 * its own static OSAtomic fallbacks and must not see the header. The lock
 * is per translation unit, which is
 * enough for callers that keep every update of a counter in one file --
 * check that before relying on it elsewhere. */
#if defined(__cplusplus) && defined(__ppc__) && !defined(__ppc64__)
#include <stdint.h>
#include <pthread.h>
#include <libkern/OSAtomic.h>	/* first, so its guard keeps any later
				   declaration from meeting the #define */
static pthread_mutex_t leopard_atomic64_lock = PTHREAD_MUTEX_INITIALIZER;
static inline int64_t
leopard_OSAtomicAdd64(int64_t amount, volatile int64_t *value)
{
	int64_t v;

	pthread_mutex_lock(&leopard_atomic64_lock);
	v = (*value += amount);
	pthread_mutex_unlock(&leopard_atomic64_lock);
	return v;
}
#define OSAtomicAdd64 leopard_OSAtomicAdd64
#endif

/* clock_gettime: 10.12. Needed by mbedTLS 3.6 (platform_util.c). MONOTONIC
 * is mach_absolute_time() scaled by the timebase; REALTIME is
 * gettimeofday(), so it has microsecond resolution. */
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101200 && !defined(CLOCK_MONOTONIC)
#include <time.h>
#include <errno.h>
#include <sys/time.h>
#include <mach/mach_time.h>
typedef int clockid_t;
#define CLOCK_REALTIME	0
#define CLOCK_MONOTONIC	6
static inline int
leopard_clock_gettime(clockid_t id, struct timespec *ts)
{
	if (id == CLOCK_REALTIME) {
		struct timeval tv;

		gettimeofday(&tv, 0);
		ts->tv_sec = tv.tv_sec;
		ts->tv_nsec = tv.tv_usec * 1000;
		return 0;
	}
	if (id == CLOCK_MONOTONIC) {
		static mach_timebase_info_data_t tb;
		unsigned long long ns;

		if (tb.denom == 0)
			mach_timebase_info(&tb);
		ns = mach_absolute_time() * tb.numer / tb.denom;
		ts->tv_sec = (time_t)(ns / 1000000000ULL);
		ts->tv_nsec = (long)(ns % 1000000000ULL);
		return 0;
	}
	errno = EINVAL;
	return -1;
}
#define clock_gettime leopard_clock_gettime
#endif

#endif /* LEOPARD_COMPAT_H */
