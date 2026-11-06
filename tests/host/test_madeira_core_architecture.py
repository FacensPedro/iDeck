import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class MadeiraCoreArchitectureTests(unittest.TestCase):
    def test_config_settings_use_single_snapshot(self):
        config = (ROOT / "iDeck/MadeiraConfig.swift").read_text(encoding="utf-8")
        self.assertIn("private static func snapshot() -> (exists: Bool, values: [String: String])", config)
        self.assertIn("static func all() -> [String: String] { snapshot().values }", config)
        get_body = config.split("static func get(_ key: String) -> String? {", 1)[1].split("\n    }", 1)[0]
        flag_body = config.split("static func flag(_ name: String, fallback: Bool = true) -> Bool {", 1)[1].split("\n    }", 1)[0]
        self.assertEqual(get_body.count("snapshot()"), 1)
        self.assertEqual(flag_body.count("snapshot()"), 1)
        self.assertNotIn("presentCached", config)
        self.assertIn('madeira-\\(key).txt', get_body)
        self.assertIn("info.st_ino", config)

    def test_native_memory_manager_avoids_redundant_pool_snapshots(self):
        manager = (ROOT / "iDeck/NativeRuntime/NativeMemoryManager.cpp").read_text(encoding="utf-8")
        pool = (ROOT / "iDeck/NativeRuntime/GuestMemoryPool.cpp").read_text(encoding="utf-8")
        header = (ROOT / "iDeck/NativeRuntime/NativePerformance.h").read_text(encoding="utf-8")
        self.assertIn("ideck_memory_pool_set_cache_limit_reclaimed(s.pool, limit)", manager)
        self.assertIn("ideck_memory_pool_trim_reclaimed(s.pool)", manager)
        self.assertIn("before - pool->cached_bytes", pool)
        self.assertIn("const size_t reclaimed = pool->cached_bytes", pool)
        self.assertIn("ideck_memory_pool_trim_reclaimed", header)
        self.assertIn("ideck_memory_pool_set_cache_limit_reclaimed", header)
        self.assertIn("ideck_memory_pool_set_cache_limit(", header)
        self.assertIn("ideck_memory_pool_trim(", header)

    def test_native_jit_and_wine_ownership_remains_intact(self):
        coordinator = (ROOT / "iDeck/SystemCoordinator.swift").read_text(encoding="utf-8")
        self.assertIn("ideck_native_memory_install_notifications()", coordinator)
        self.assertIn("ideck_native_memory_configure(64 * 1024 * 1024, 8 * 1024 * 1024)", coordinator)
        self.assertIn("guard ensureJITForGameLaunch() else { return }", coordinator)


if __name__ == "__main__":
    unittest.main()
