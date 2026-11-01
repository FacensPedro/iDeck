"""Execute the production candidate selector without Apple SDK dependencies."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class WinePoolCandidateRecoveryTests(unittest.TestCase):
    def test_cached_fallback_does_not_permanently_cap_steam_pool(self):
        compiler = shutil.which("c++")
        if not compiler:
            self.skipTest("C++ compiler unavailable")
        source = (ROOT / "iDeck/NativeRuntime/FEXRuntime.cpp").read_text()
        selector = source.split("std::vector<size_t> wine_pool_candidates() {", 1)[1]
        selector = "std::vector<size_t> wine_pool_candidates() {" + selector.split(
            "\nvoid record_wine_pool_failure", 1
        )[0]
        harness = r"""
#include <vector>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cerrno>
#include <cassert>
static uint64_t memory = 8ULL << 30;
int sysctlbyname(const char *, void *out, size_t *, void *, size_t) {
    *static_cast<uint64_t *>(out) = memory;
    return 0;
}
"""
        harness += selector
        harness += r"""
int main() {
    unsetenv("IDECK_WINE_JIT_MIB");
    for (const char *cached : {"256", "384", "invalid", "0"}) {
        setenv("IDECK_WINE_JIT_LAST_GOOD_MIB", cached, 1);
        auto sizes = wine_pool_candidates();
        assert(sizes.front() == (896ULL << 20));
        assert(sizes.back() == (256ULL << 20));
    }
    setenv("IDECK_WINE_JIT_LAST_GOOD_MIB", "512", 1);
    assert(wine_pool_candidates().front() == (512ULL << 20));
    setenv("IDECK_WINE_JIT_MIB", "640", 1);
    assert(wine_pool_candidates().front() == (640ULL << 20));
    setenv("IDECK_WINE_JIT_MIB", "256", 1);
    assert(wine_pool_candidates().front() == (256ULL << 20));
    unsetenv("IDECK_WINE_JIT_MIB");
    memory = 2ULL << 30;
    assert(wine_pool_candidates().front() == (384ULL << 20));
}
"""
        with tempfile.TemporaryDirectory() as tmp:
            cpp = pathlib.Path(tmp) / "selector.cpp"
            exe = pathlib.Path(tmp) / "selector"
            cpp.write_text(harness)
            subprocess.run([compiler, "-std=c++17", str(cpp), "-o", str(exe)], check=True)
            subprocess.run([str(exe)], check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
