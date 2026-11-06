// Madeira core: JIT/FEX memory, runtime errors, Windows paths and the
// statically linked D3D12 canary. Platform (Metal/UIKit) code lives in
// MadeiraPlatform.mm.
#include "RuntimeSupport.h"
#include "MadeiraStaticABI.h"
#include "MadeiraRuntimeBridge.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>
#include <sys/mman.h>
#include <unistd.h>

// MARK: - JIT memory

extern "C" void *ideck_jit_allocate(size_t size) {
    if (!size) { errno = EINVAL; return nullptr; }
    void *memory = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    return memory == MAP_FAILED ? nullptr : memory;
}

extern "C" int32_t ideck_jit_make_executable(void *address, size_t size) {
    if (!address || !size) return EINVAL;
    long page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0 || (reinterpret_cast<uintptr_t>(address) % static_cast<uintptr_t>(page_size)) != 0) return EINVAL;
    if (mprotect(address, size, PROT_READ | PROT_EXEC) != 0) return errno;
    return 0;
}

extern "C" void ideck_jit_deallocate(void *address, size_t size) {
    if (address && size) (void)munmap(address, size);
}

// MARK: - FEX memory

extern "C" void *ideck_fex_memory_reserve(size_t length) {
    if (!length) { errno = EINVAL; return nullptr; }
    return ideck_jit_allocate(length);
}

extern "C" void ideck_fex_memory_release(void *memory, size_t length) {
    ideck_jit_deallocate(memory, length);
}

// MARK: - Runtime errors

static std::atomic<int32_t> last_error{0};
static std::mutex error_mutex;

extern "C" void ideck_runtime_report_error(int32_t code, const char *message) {
    last_error.store(code);
    std::lock_guard<std::mutex> lock(error_mutex);
    std::fprintf(stderr, "iDeck native runtime error %d: %s\n", code, message ? message : "unspecified");
}

extern "C" int32_t ideck_runtime_last_error(void) { return last_error.load(); }

// MARK: - Windows paths

extern "C" bool ideck_windows_to_unix_path(const char *prefix, const char *windows_path, char *output, size_t capacity) {
    if (!prefix || !windows_path || !output || !capacity) return false;
    std::string path(windows_path);
    if (path.size() < 3 || std::tolower(static_cast<unsigned char>(path[0])) != 'c' || path[1] != ':' || (path[2] != '\\' && path[2] != '/')) return false;
    std::replace(path.begin(), path.end(), '\\', '/');
    std::vector<std::string> components;
    size_t start = 3;
    while (start <= path.size()) {
        auto end = path.find('/', start);
        std::string part = path.substr(start, end == std::string::npos ? end : end - start);
        if (part == ".." || part.find(':') != std::string::npos) return false;
        if (!part.empty() && part != ".") components.push_back(part);
        if (end == std::string::npos) break;
        start = end + 1;
    }
    std::string result = std::string(prefix) + "/drive_c";
    for (const auto &part : components) result += "/" + part;
    if (result.size() + 1 > capacity) return false;
    std::memcpy(output, result.c_str(), result.size() + 1);
    return true;
}

// MARK: - D3D12

extern "C" bool ideck_d3d12_available(void) {
#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED && \
    defined(IDECK_MADEIRA_D3D12_ENABLED) && IDECK_MADEIRA_D3D12_ENABLED
    // The real native D3D12 canary is supplied by DXMT's static archive.
    return &madeira_d3d12_canary_run != nullptr;
#else
    return false;
#endif
}
