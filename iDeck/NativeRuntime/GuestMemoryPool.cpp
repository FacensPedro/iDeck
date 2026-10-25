#include "NativePerformance.h"

#include <cstdlib>
#include <limits>
#include <mutex>
#include <new>
#include <unordered_map>
#include <vector>

struct IDeckGuestMemoryPool {
    struct Block {
        void *pointer;
        size_t size;
    };

    explicit IDeckGuestMemoryPool(size_t limit) : cache_limit(limit) {}

    size_t cache_limit;
    std::mutex mutex;
    std::unordered_map<void *, size_t> active;
    std::vector<Block> cached;
    size_t active_bytes = 0;
    size_t cached_bytes = 0;
};

extern "C" IDeckGuestMemoryPool *ideck_memory_pool_create(size_t max_cached_bytes) {
    return new (std::nothrow) IDeckGuestMemoryPool(max_cached_bytes);
}

extern "C" void *ideck_memory_pool_acquire(IDeckGuestMemoryPool *pool, size_t size) {
    if (!pool || !size) return nullptr;
    std::lock_guard<std::mutex> lock(pool->mutex);
    if (size > std::numeric_limits<size_t>::max() - pool->active_bytes) return nullptr;
    for (size_t index = 0; index < pool->cached.size(); ++index) {
        const auto &block = pool->cached[index];
        if (block.size < size || block.size - size > size) continue;
        try {
            pool->active.emplace(block.pointer, block.size);
        } catch (...) {
            return nullptr;
        }
        void *pointer = block.pointer;
        pool->active_bytes += block.size;
        pool->cached_bytes -= block.size;
        pool->cached.erase(pool->cached.begin() + index);
        return pointer;
    }
    void *pointer = std::malloc(size);
    if (!pointer) return nullptr;
    try {
        pool->active.emplace(pointer, size);
    } catch (...) {
        std::free(pointer);
        return nullptr;
    }
    pool->active_bytes += size;
    return pointer;
}

extern "C" bool ideck_memory_pool_release(IDeckGuestMemoryPool *pool, void *pointer) {
    if (!pool || !pointer) return false;
    std::lock_guard<std::mutex> lock(pool->mutex);
    auto found = pool->active.find(pointer);
    if (found == pool->active.end()) return false;
    size_t size = found->second;
    pool->active_bytes -= size;
    pool->active.erase(found);
    if (size <= pool->cache_limit - pool->cached_bytes) {
        try {
            pool->cached.push_back({pointer, size});
            pool->cached_bytes += size;
            return true;
        } catch (...) {
        }
    }
    std::free(pointer);
    return true;
}

extern "C" bool ideck_memory_pool_stats(const IDeckGuestMemoryPool *pool, IDeckMemoryPoolStats *output) {
    if (!pool || !output) return false;
    auto *state = const_cast<IDeckGuestMemoryPool *>(pool);
    std::lock_guard<std::mutex> lock(state->mutex);
    *output = {state->active.size(), state->active_bytes, state->cached.size(), state->cached_bytes};
    return true;
}

extern "C" void ideck_memory_pool_trim(IDeckGuestMemoryPool *pool) {
    if (!pool) return;
    std::lock_guard<std::mutex> lock(pool->mutex);
    for (auto block : pool->cached) std::free(block.pointer);
    pool->cached.clear();
    pool->cached_bytes = 0;
}

extern "C" bool ideck_memory_pool_set_cache_limit(IDeckGuestMemoryPool *pool, size_t max_cached_bytes) {
    if (!pool) return false;
    std::lock_guard<std::mutex> lock(pool->mutex);
    pool->cache_limit = max_cached_bytes;
    while (pool->cached_bytes > max_cached_bytes && !pool->cached.empty()) {
        auto block = pool->cached.back();
        pool->cached.pop_back();
        pool->cached_bytes -= block.size;
        std::free(block.pointer);
    }
    return true;
}

extern "C" void ideck_memory_pool_destroy(IDeckGuestMemoryPool *pool) {
    if (!pool) return;
    for (auto item : pool->active) std::free(item.first);
    for (auto block : pool->cached) std::free(block.pointer);
    delete pool;
}
