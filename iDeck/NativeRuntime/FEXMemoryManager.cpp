#include "RuntimeSupport.h"
#include "MadeiraRuntimeBridge.h"
#include <cerrno>
#include <sys/mman.h>
extern "C" void *ideck_fex_memory_reserve(size_t length) {
    if (!length) { errno = EINVAL; return nullptr; }
    return ideck_jit_allocate(length);
}
extern "C" void ideck_fex_memory_release(void *memory, size_t length) {
    ideck_jit_deallocate(memory, length);
}
