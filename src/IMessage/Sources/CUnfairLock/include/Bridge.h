#include <os/lock.h>

#define OS_UNFAIR_LOCK_DATA_SYNCHRONIZATION  ((uint32_t)0x00010000)
#define OS_UNFAIR_LOCK_ADAPTIVE_SPIN         ((uint32_t)0x00040000)

typedef uint32_t os_unfair_lock_options_t;

void os_unfair_lock_lock_with_options(os_unfair_lock_t lock,
		os_unfair_lock_options_t options);
