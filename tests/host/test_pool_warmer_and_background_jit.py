import unittest

from support import patch_group, repo_text

PATCH = repo_text("patches/madeira-pool-warmer-forget.patch")
POOL = repo_text("iDeck/MadeiraJIT/MadeiraWinePool.swift")
BRIDGE = repo_text("iDeck/NativeRuntime/MadeiraRuntimeBridge.h")
STIK = repo_text("iDeck/MadeiraJIT/StikJITHelper.swift")


class PoolWarmerForgetTests(unittest.TestCase):
    def test_patch_is_listed_and_stops_the_warmer(self):
        self.assertEqual(patch_group("madeira-pool-warmer-forget.patch"), "native")
        self.assertIn("+void ideck_wine_jit_pool_forget( void )", PATCH)
        self.assertIn("+        if (__atomic_load_n( &ios_pool_gone, __ATOMIC_SEQ_CST ))", PATCH)
        self.assertIn("ios_pool_gone, 0, __ATOMIC_SEQ_CST );   /* iDeck: a new pool", PATCH)

    def test_release_forgets_before_unmapping(self):
        self.assertIn("void ideck_wine_jit_pool_forget(void);", BRIDGE)
        start = POOL.index("static func release() -> Int?")
        body = POOL[start:POOL.index("return mb", start)]
        self.assertLess(body.index("ideck_wine_jit_pool_forget()"), body.index("StikJITHelper.discardPool(pool)"))


class StikDebugInBackgroundTests(unittest.TestCase):
    def test_stikdebug_opens_only_in_front(self):
        self.assertIn("static func whenActive(_ body: @escaping () -> Void)", STIK)
        self.assertIn("UIApplication.didBecomeActiveNotification", STIK)
        self.assertEqual(STIK.count("whenActive {"), 2)


if __name__ == "__main__":
    unittest.main()
