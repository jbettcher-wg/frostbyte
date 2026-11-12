/* toolchain/sdkfix: fixes for 10.5 SDK header BUGS, safe for every build (they change no
 * function availability, so autoconf/meson probes see the same libc). Builds put this
 * directory on -isystem: deps/build-deps.sh and frostbyte/build.sh; WebKit gets the same fix
 * from the force-included toolchain/leopard-compat.h.
 *
 * sys/socket.h: the SDK's LP64 CMSG_* macros pad the cmsghdr to 16 bytes, which no Leopard
 * kernel understands; see ../../leopard-cmsg.h. */
#include_next <sys/socket.h>
#include "../../leopard-cmsg.h"
