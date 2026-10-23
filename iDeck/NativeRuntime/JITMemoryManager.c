#include "MadeiraRuntimeBridge.h"
#include <errno.h>
#include <sys/mman.h>
#include <unistd.h>
void *ideck_jit_allocate(size_t size) {
    if (!size) { errno = EINVAL; return NULL; }
    void *memory = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    return memory == MAP_FAILED ? NULL : memory;
}
int32_t ideck_jit_make_executable(void *address, size_t size) {
    if (!address || !size) return EINVAL;
    long page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0 || ((uintptr_t)address % (uintptr_t)page_size) != 0) return EINVAL;
    if (mprotect(address, size, PROT_READ | PROT_EXEC) != 0) return errno;
    return 0;
}
void ideck_jit_deallocate(void *address, size_t size) {
    if (address && size) (void)munmap(address, size);
}
