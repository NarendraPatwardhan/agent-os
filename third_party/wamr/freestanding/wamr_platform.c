#include "platform_api_extension.h"
#include "platform_api_vmcore.h"

#include <errno.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

int
bh_platform_init(void)
{
    return 0;
}

void
bh_platform_destroy(void)
{}

void *
os_malloc(unsigned size)
{
    return malloc((size_t)size);
}

void *
os_realloc(void *ptr, unsigned size)
{
    return realloc(ptr, (size_t)size);
}

void
os_free(void *ptr)
{
    free(ptr);
}

int
os_printf(const char *format, ...)
{
    (void)format;
    return 0;
}

int
os_vprintf(const char *format, va_list ap)
{
    (void)format;
    (void)ap;
    return 0;
}

uint64
os_time_get_boot_us(void)
{
    return 0;
}

uint64
os_time_thread_cputime_us(void)
{
    return 0;
}

korp_tid
os_self_thread(void)
{
    return 1;
}

uint8 *
os_thread_get_stack_boundary(void)
{
    return NULL;
}

void
os_thread_jit_write_protect_np(bool enabled)
{
    (void)enabled;
}

int
os_mutex_init(korp_mutex *mutex)
{
    if (mutex) mutex->unused = 0;
    return 0;
}

int
os_mutex_destroy(korp_mutex *mutex)
{
    (void)mutex;
    return 0;
}

int
os_mutex_lock(korp_mutex *mutex)
{
    (void)mutex;
    return 0;
}

int
os_mutex_unlock(korp_mutex *mutex)
{
    (void)mutex;
    return 0;
}

void *
os_mmap(void *hint, size_t size, int prot, int flags, os_file_handle file)
{
    (void)hint;
    (void)prot;
    (void)flags;
    (void)file;

    void *ptr = malloc(size);
    if (ptr) memset(ptr, 0, size);
    return ptr;
}

void
os_munmap(void *addr, size_t size)
{
    (void)size;
    free(addr);
}

int
os_mprotect(void *addr, size_t size, int prot)
{
    (void)addr;
    (void)size;
    (void)prot;
    return 0;
}

void *
os_mremap(void *old_addr, size_t old_size, size_t new_size)
{
    void *new_addr = malloc(new_size);
    if (!new_addr) return NULL;
    if (old_addr) {
        memcpy(new_addr, old_addr, old_size < new_size ? old_size : new_size);
        free(old_addr);
    }
    return new_addr;
}

void
os_dcache_flush(void)
{}

void
os_icache_flush(void *start, size_t len)
{
    (void)start;
    (void)len;
}

int
os_thread_create(korp_tid *p_tid, thread_start_routine_t start, void *arg,
                 unsigned int stack_size)
{
    (void)p_tid;
    (void)start;
    (void)arg;
    (void)stack_size;
    errno = ENOSYS;
    return -1;
}

int
os_thread_create_with_prio(korp_tid *p_tid, thread_start_routine_t start,
                           void *arg, unsigned int stack_size, int prio)
{
    (void)prio;
    return os_thread_create(p_tid, start, arg, stack_size);
}

int
os_thread_join(korp_tid thread, void **retval)
{
    (void)thread;
    (void)retval;
    return 0;
}

int
os_thread_detach(korp_tid thread)
{
    (void)thread;
    return 0;
}

void
os_thread_exit(void *retval)
{
    (void)retval;
    __builtin_trap();
}

int
os_thread_env_init(void)
{
    return 0;
}

void
os_thread_env_destroy(void)
{}

bool
os_thread_env_inited(void)
{
    return true;
}

int
os_usleep(uint32 usec)
{
    (void)usec;
    return 0;
}

int
os_recursive_mutex_init(korp_mutex *mutex)
{
    return os_mutex_init(mutex);
}

int
os_cond_init(korp_cond *cond)
{
    if (cond) cond->unused = 0;
    return 0;
}

int
os_cond_destroy(korp_cond *cond)
{
    (void)cond;
    return 0;
}

int
os_cond_wait(korp_cond *cond, korp_mutex *mutex)
{
    (void)cond;
    (void)mutex;
    return 0;
}

int
os_cond_reltimedwait(korp_cond *cond, korp_mutex *mutex, uint64 useconds)
{
    (void)cond;
    (void)mutex;
    (void)useconds;
    return BHT_TIMED_OUT;
}

int
os_cond_signal(korp_cond *cond)
{
    (void)cond;
    return 0;
}

int
os_cond_broadcast(korp_cond *cond)
{
    (void)cond;
    return 0;
}

int
os_rwlock_init(korp_rwlock *lock)
{
    if (lock) lock->unused = 0;
    return 0;
}

int
os_rwlock_rdlock(korp_rwlock *lock)
{
    (void)lock;
    return 0;
}

int
os_rwlock_wrlock(korp_rwlock *lock)
{
    (void)lock;
    return 0;
}

int
os_rwlock_unlock(korp_rwlock *lock)
{
    (void)lock;
    return 0;
}

int
os_rwlock_destroy(korp_rwlock *lock)
{
    (void)lock;
    return 0;
}

korp_sem *
os_sem_open(const char *name, int oflags, int mode, int val)
{
    (void)name;
    (void)oflags;
    (void)mode;
    (void)val;
    errno = ENOSYS;
    return NULL;
}

int
os_sem_close(korp_sem *sem)
{
    (void)sem;
    return 0;
}

int
os_sem_wait(korp_sem *sem)
{
    (void)sem;
    return 0;
}

int
os_sem_trywait(korp_sem *sem)
{
    (void)sem;
    return 0;
}

int
os_sem_post(korp_sem *sem)
{
    (void)sem;
    return 0;
}

int
os_sem_getvalue(korp_sem *sem, int *sval)
{
    (void)sem;
    if (sval) *sval = 0;
    return 0;
}

int
os_sem_unlink(const char *name)
{
    (void)name;
    return 0;
}

int
os_blocking_op_init(void)
{
    return 0;
}

void
os_begin_blocking_op(void)
{}

void
os_end_blocking_op(void)
{}

int
os_wakeup_blocking_op(korp_tid tid)
{
    (void)tid;
    return 0;
}

int
os_dumps_proc_mem_info(char *out, unsigned int size)
{
    if (out && size > 0) out[0] = '\0';
    return -1;
}
