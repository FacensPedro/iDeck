import unittest

from support import ROOT, repo_text


class DXMTiOSCacheSyncReuseTests(unittest.TestCase):
    def setUp(self):
        self.patch = (ROOT / "patches/dxmt-ios-cache-sync-reuse.patch").read_text()

    def test_reader_reopens_after_first_write(self):
        self.assertIn("reader_retry_.exchange(false", self.patch)
        self.assertIn("std::unique_lock<dxmt::mutex> lock(scache_reader_mutex_)", self.patch)
        self.assertIn("std::adopt_lock", self.patch)
        self.assertIn("+      cache->scache_.noteWritten();", self.patch)
        self.assertIn("+    d9_shader_cache().noteWritten();", self.patch)

    def test_bounded_wait_parks_in_kernel(self):
        self.assertIn("+  return cpu_coherent.wait_until<clock>(seq, deadline);", self.patch)
        self.assertIn("RtlWaitOnAddress(addr, compare, (SIZE_T)size, &timeout);", self.patch)
        self.assertIn("-    this_thread::yield();", self.patch)

    def test_memory_pressure_trims_and_app_publishes_word(self):
        self.assertIn("const uint64_t DYN_KEEP_ELIGIBLE = env::iosMemoryPressure() ? 0 : 64;", self.patch)
        bridge = repo_text("iDeck/NativeRuntime/MadeiraRuntimeBridge.mm")
        self.assertIn("DISPATCH_SOURCE_TYPE_MEMORYPRESSURE", bridge)
        self.assertIn('setenv("IDECK_MEMORY_PRESSURE_ADDR", addr, 1);', bridge)
        self.assertLess(bridge.index("static void ideck_memory_pressure_publish(void)"),
                        bridge.index("ideck_memory_pressure_publish();"))

    def test_frame_latency_default_and_zero_means_default(self):
        self.assertIn("long n = v.empty() ? 2 : std::strtol(v.c_str(), nullptr, 10);", self.patch)
        self.assertIn("cmd_queue_.SetMaxLatency(MaxLatency ? MaxLatency : CommandQueue::DefaultMaxLatency());", self.patch)

    def test_bounded_db_and_opt_in_pipeline_archive(self):
        self.assertIn('getenv("DXMT_SHADER_CACHE_MAX_MB")', self.patch)
        self.assertIn('env::getEnvVar("DXMT_PIPELINE_ARCHIVE") != "1"', self.patch)
        self.assertIn("+  'dxmt_pipeline_archive.cpp',", self.patch)
        self.assertIn("wmt_resolve_cache_file(path)", self.patch)

    def test_patch_applied_and_hashed(self):
        self.assertIn('DXMT_IOS_PATCH="$ROOT/patches/dxmt-ios-cache-sync-reuse.patch"',
                      repo_text("scripts/fetch_madeira_sources.sh"))
        self.assertIn('"patches/dxmt-ios-cache-sync-reuse.patch"', repo_text("scripts/madeira_native_kit.py"))


if __name__ == "__main__":
    unittest.main()
