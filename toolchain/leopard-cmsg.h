/* leopard-cmsg.h -- the 10.5 SDK's LP64 CMSG_* bug, fixed the way 10.6 fixed it.
 *
 * The Mac OS X 10.5 SDK builds every CMSG_* macro on __DARWIN_ALIGN, which aligns to
 * sizeof(long). In a 64-bit (ppc64) program that puts CMSG_DATA() 16 bytes past the 12-byte
 * cmsghdr and makes CMSG_SPACE(4) 24 while CMSG_LEN(4) is 20. The kernel does not agree:
 * Leopard's xnu-1228 uses the PACKED layout for every process width -- descriptors directly
 * after the 12-byte header, cmsg_len == m_len (unp_internalize/unp_externalize) -- and so do the
 * 10.6+ headers, whose CMSG_* use __DARWIN_ALIGN32. Real Leopard ppc64 binaries (Chromium
 * Aurora, for one) send that layout.
 *
 * With the SDK's macros a 64-bit sender either gets EINVAL (cmsg_len != controllen) or, with the
 * padding trimmed, ships the 4 pad bytes at +12 as an extra descriptor (usually a dup of fd 0)
 * and a 64-bit receiver reads its descriptor 4 bytes too far. This header redefines the macros
 * to the 10.6 definitions (sys/socket.h, xnu-1456) for LP64. ILP32 (ppc) is untouched: there
 * __DARWIN_ALIGN already is 4-byte alignment, so the SDK's macros are the packed ones.
 *
 * Pulled in after the SDK's <sys/socket.h> two ways, so the order of a translation unit's own
 * includes never matters:
 *   - toolchain/leopard-compat.h (force-included into WebKit and our C/C++) includes
 *     <sys/socket.h> and then this file;
 *   - toolchain/sdkfix/sys/socket.h wraps the SDK header (#include_next) for builds that must not
 *     get the compat header (deps/build-deps.sh: it breaks autoconf/meson probes).
 */
#ifndef LEOPARD_CMSG_H
#define LEOPARD_CMSG_H
#ifndef __ASSEMBLER__
#include <sys/socket.h>

#if defined(__LP64__) || defined(__ppc64__)

#ifndef __DARWIN_ALIGNBYTES32
#define __DARWIN_ALIGNBYTES32	(sizeof(__uint32_t) - 1)
#endif
#ifndef __DARWIN_ALIGN32
#define __DARWIN_ALIGN32(p)	((__darwin_size_t)((char *)(__darwin_size_t)(p) + __DARWIN_ALIGNBYTES32) &~ __DARWIN_ALIGNBYTES32)
#endif

#undef CMSG_DATA
#undef CMSG_FIRSTHDR
#undef CMSG_NXTHDR
#undef CMSG_SPACE
#undef CMSG_LEN

/* given pointer to struct cmsghdr, return pointer to data */
#define	CMSG_DATA(cmsg)		((unsigned char *)(cmsg) + \
				 __DARWIN_ALIGN32(sizeof(struct cmsghdr)))

/* RFC 2292 requires to check msg_controllen, in case that the kernel returns an empty list
 * for some reasons. */
#define	CMSG_FIRSTHDR(mhdr) \
	((mhdr)->msg_controllen >= sizeof(struct cmsghdr) ? \
	    (struct cmsghdr *)(mhdr)->msg_control : \
	    (struct cmsghdr *)0L)

/* given pointer to struct cmsghdr, return pointer to next cmsghdr; RFC 2292 says that
 * CMSG_NXTHDR(mhdr, NULL) is equivalent to CMSG_FIRSTHDR(mhdr) */
#define	CMSG_NXTHDR(mhdr, cmsg)						\
	((char *)(cmsg) == (char *)0L ? CMSG_FIRSTHDR(mhdr) :		\
	    ((((unsigned char *)(cmsg) +					\
	    __DARWIN_ALIGN32((__uint32_t)(cmsg)->cmsg_len) +		\
	    __DARWIN_ALIGN32(sizeof(struct cmsghdr))) >			\
	    ((unsigned char *)(mhdr)->msg_control +			\
	    (mhdr)->msg_controllen)) ?					\
	    (struct cmsghdr *)0L /* NULL */ :				\
	    (struct cmsghdr *)(void *)((unsigned char *)(cmsg) +	\
	    __DARWIN_ALIGN32((__uint32_t)(cmsg)->cmsg_len))))

#if !defined(_POSIX_C_SOURCE) || defined(_DARWIN_C_SOURCE)
/* RFC 2292 additions (same visibility as the SDK's) */
#define	CMSG_SPACE(l)		(__DARWIN_ALIGN32(sizeof(struct cmsghdr)) + __DARWIN_ALIGN32(l))
#define	CMSG_LEN(l)		(__DARWIN_ALIGN32(sizeof(struct cmsghdr)) + (l))
#endif

#endif /* __LP64__ */
#endif /* __ASSEMBLER__ */
#endif /* LEOPARD_CMSG_H */
