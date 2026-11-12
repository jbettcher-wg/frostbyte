/* <os/lock.h> is 10.12+. Leopard has OSSpinLock in <libkern/OSAtomic.h>; an
 * os_unfair_lock is the same 32-bit word with the same zero-initialised
 * unlocked state, so this header-only shim is what MacPorts legacy-support
 * does too, minus its library symbol. */
#ifndef LEOPARD_SHIM_OS_LOCK_H
#define LEOPARD_SHIM_OS_LOCK_H
#include <stdint.h>
#include <stdbool.h>
#include <libkern/OSAtomic.h>
typedef struct os_unfair_lock_s { uint32_t _os_unfair_lock_opaque; } os_unfair_lock, *os_unfair_lock_t;
#define OS_UNFAIR_LOCK_INIT ((os_unfair_lock){0})
static inline void os_unfair_lock_lock(os_unfair_lock_t l)   { OSSpinLockLock((volatile OSSpinLock*)&l->_os_unfair_lock_opaque); }
static inline bool os_unfair_lock_trylock(os_unfair_lock_t l){ return OSSpinLockTry((volatile OSSpinLock*)&l->_os_unfair_lock_opaque); }
static inline void os_unfair_lock_unlock(os_unfair_lock_t l) { OSSpinLockUnlock((volatile OSSpinLock*)&l->_os_unfair_lock_opaque); }
static inline void os_unfair_lock_assert_owner(os_unfair_lock_t l)     { (void)l; }
static inline void os_unfair_lock_assert_not_owner(os_unfair_lock_t l) { (void)l; }
#endif
