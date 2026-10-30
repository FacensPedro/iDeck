#ifndef IDECK_JIT_REGION_POLICY_H
#define IDECK_JIT_REGION_POLICY_H

#include <cstddef>
#include <cstdint>

namespace ideck::jit {
constexpr bool disjoint(std::uintptr_t rx, std::uintptr_t rw, std::size_t size) {
    return rx != 0 && rw != 0 && size != 0 &&
        rx <= UINTPTR_MAX - size &&
        rw <= UINTPTR_MAX - size &&
        (rw >= rx + size || rx >= rw + size);
}

constexpr bool executable_only(unsigned current, unsigned execute, unsigned write) {
    return (current & execute) == execute && (current & write) == 0;
}

constexpr bool writable_only(unsigned current, unsigned read, unsigned write, unsigned execute) {
    return (current & (read | write)) == (read | write) &&
        (current & execute) == 0;
}
}

#endif
