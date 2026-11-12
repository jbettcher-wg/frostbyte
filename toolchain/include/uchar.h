/* <uchar.h> (C11) is absent from the 10.5 SDK. C++ has char16_t/char32_t as
 * keywords; C translation units get the C11 typedefs. simdutf probes for
 * this header with __has_include and otherwise typedefs its own, which then
 * clashes with the C++ keyword in the same translation unit. */
#ifndef LEOPARD_SHIM_UCHAR_H
#define LEOPARD_SHIM_UCHAR_H
#include <stdint.h>
#ifndef __cplusplus
typedef uint_least16_t char16_t;
typedef uint_least32_t char32_t;
#endif
#endif
