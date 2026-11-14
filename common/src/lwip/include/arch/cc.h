#ifndef lwip__cc_h
#define lwip__cc_h

#include <stdbool.h>
#include <stdint.h>

typedef unsigned int sys_prot_t;

extern uint32_t lwip_rand(void);
extern void lwip_assert_core_locked();
extern void lwip_assert(const char *msg, const char *file, int line);
extern void lwip_diag(const char *msg, const char *file, int line);

#define LWIP_ASSERT_CORE_LOCKED()   do { lwip_assert_core_locked(); } while (0)

// `x` is a parenthesised printf argument list, which lwip_diag can't format: only the
// location is logged.
#define LWIP_PLATFORM_DIAG(x)                                                  \
    do {                                                                       \
        lwip_diag("lwIP diagnostic", __FILE__, __LINE__);                      \
    } while (0)
#define LWIP_PLATFORM_ASSERT(msg)                                              \
    do {                                                                       \
        lwip_assert((msg), __FILE__, __LINE__);                                \
    } while (0)

#define BYTE_ORDER LITTLE_ENDIAN

#define LWIP_RAND() ((u32_t)lwip_rand())

#define LWIP_NO_STDDEF_H 0
#define LWIP_NO_STDINT_H 0
#define LWIP_NO_INTTYPES_H 1
#define LWIP_NO_LIMITS_H 0
#define LWIP_NO_CTYPE_H 1

#define LWIP_UNUSED_ARG(x) (void)x
#define LWIP_PROVIDE_ERRNO 0

// SYS_ARCH_PROTECT is lwIP's default, `lev = sys_arch_protect()`: a critical section
// (interrupts off) whose previous state is kept in `lev`, so it nests and works from an ISR.
// See sys_arch_protect in exports.zig.

#endif // lwip__cc_h
