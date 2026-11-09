"""iDeck's JIT is Madeira's: StikJITHelper, EntitlementChecker and JITAllocator.h
copied verbatim into iDeck/MadeiraJIT; the pool comes from StikJITHelper at
launch, followed by Madeira's early detach."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def read(path):
    return (ROOT / path).read_text()


class MadeiraJITVerbatimTests(unittest.TestCase):
    def test_madeira_files_are_present(self):
        helper = read("iDeck/MadeiraJIT/StikJITHelper.swift")
        self.assertIn("static func allocatePool(poolSize requestedPoolSize: Int = 128 * 1024 * 1024)", helper)
        self.assertIn("static func enableJIT(completion: @escaping (Result<Void, Error>) -> Void)", helper)
        self.assertIn("static func detachDebugger()", helper)
        self.assertIn("struct SigningStatus", read("iDeck/MadeiraJIT/EntitlementChecker.swift"))
        self.assertIn("void *jit26_prepare_region(void *addr, size_t len);", read("iDeck/MadeiraJIT/JITAllocator.h"))

    def test_launch_allocates_exports_and_detaches_as_madeira(self):
        pool = read("iDeck/MadeiraJIT/MadeiraWinePool.swift")
        self.assertIn("StikJITHelper.allocatePool(poolSize: poolSizeMB * 1024 * 1024)", pool)
        self.assertIn('setenv("WINE_IOS_JIT_RX"', pool)
        self.assertIn("StikJITHelper.detachDebugger()", pool)
        self.assertIn("MadeiraWinePool.prepare()", read("iDeck/WindowsEnvironment.swift"))

    def test_ideck_pool_code_is_gone(self):
        fex = read("iDeck/NativeRuntime/FEXRuntime.cpp")
        for gone in ("wine_pool_candidates", "release_placeholder_and_plug", "reserve_low_pool", "acceptable_pool"):
            self.assertNotIn(gone, fex)
        self.assertIn("return ideck_wine_jit_pool_ready();", fex)

    def test_jit_request_is_madeiras(self):
        coordinator = read("iDeck/SystemCoordinator.swift")
        self.assertIn("StikJITHelper.enableJIT {", coordinator)
        # Validated preparation: CS_DEBUGGED plus the pool or a live debugger.
        self.assertIn("guard ideck_process_has_jit_permission() else { return false }", coordinator)
        self.assertIn("return ideck_wine_jit_pool_ready() || StikJITHelper.ready", coordinator)
        self.assertIn("guard StikJITHelper.scriptData != nil else {", coordinator)
        self.assertIn("Self.recordLaunchJITState()", coordinator)


if __name__ == "__main__":
    unittest.main()
