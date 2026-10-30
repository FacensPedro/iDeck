#include <cassert>
#include <cstdint>
#include <limits>
#include <cstdio>
#include "../../iDeck/NativeRuntime/JITRegionPolicy.h"

int main() {
    constexpr unsigned read = 1, write = 2, execute = 4;
    using ideck::jit::disjoint;
    using ideck::jit::executable_only;
    using ideck::jit::writable_only;

    static_assert(executable_only(read | execute, execute, write));
    static_assert(executable_only(execute, execute, write));
    static_assert(!executable_only(read | write | execute, execute, write));
    static_assert(!executable_only(read, execute, write));
    static_assert(writable_only(read | write, read, write, execute));
    static_assert(!writable_only(read | write | execute, read, write, execute));
    static_assert(!writable_only(read, read, write, execute));
    static_assert(!writable_only(write, read, write, execute));

    constexpr std::uintptr_t rx = 0x200000000ULL;
    constexpr std::size_t size = 0x100000;
    static_assert(disjoint(rx, rx + size, size));
    static_assert(disjoint(rx, rx - size, size));
    static_assert(!disjoint(rx, rx, size));
    static_assert(!disjoint(rx, rx + size / 2, size));
    static_assert(!disjoint(rx, rx - size / 2, size));
    static_assert(!disjoint(rx, rx + 2 * size, 0));
    static_assert(!disjoint(0, rx, size));
    static_assert(!disjoint(rx, 0, size));
    static_assert(!disjoint(UINTPTR_MAX - 5, rx, size));
    static_assert(!disjoint(rx, UINTPTR_MAX - 5, size));

    assert(!disjoint(rx, rx + 8, size));
    assert(disjoint(rx, rx + size, size));
    std::puts("PASS: JIT RX/RW disjoint range boundaries and strict W^X permission policy");
    return 0;
}
