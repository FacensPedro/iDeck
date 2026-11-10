import unittest

from support import repo_text


class NoSteamIdentityTests(unittest.TestCase):
    def test_non_steam_launches_publish_no_steam_identity(self):
        script = repo_text("scripts/apply_madeira_steam_identity.py")
        self.assertIn('getenv("MADEIRA_NO_STEAM_IDENTITY")', script)
        self.assertIn('unsetenv("SteamAppId");', script)
        self.assertIn('python3 "$ROOT/scripts/apply_madeira_steam_identity.py" "$DEST"',
                      repo_text("scripts/fetch_madeira_sources.sh"))
        self.assertIn('"scripts/apply_madeira_steam_identity.py"', repo_text("scripts/madeira_native_kit.py"))
        bridge = repo_text("iDeck/NativeRuntime/MadeiraRuntimeBridge.mm")
        self.assertIn('if (![request[@"isSteam"] boolValue] && steamID == nil) {', bridge)
        self.assertIn('setenv("MADEIRA_NO_STEAM_IDENTITY", "1", 1)', bridge)


if __name__ == "__main__":
    unittest.main()
