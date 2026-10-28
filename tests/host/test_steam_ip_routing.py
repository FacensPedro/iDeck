import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DEPOT = (ROOT / "iDeck/SteamDepotDownloader.swift").read_text(encoding="utf-8")
CM = (ROOT / "iDeck/SteamManager.swift").read_text(encoding="utf-8")
FEX = (ROOT / "iDeck/NativeRuntime/FEXRuntime.cpp").read_text(encoding="utf-8")


class SteamIPRoutingTests(unittest.TestCase):
    def test_steam_content_directory_uses_actual_outgoing_ip(self):
        start = DEPOT.index("private func contentServers(appID:")
        end = DEPOT.index("nonisolated static func usableContentHost", start)
        content = DEPOT[start:end]
        self.assertIn("GetServersForSteamPipe/v1/?max_servers=32", content)
        self.assertNotIn("cell_id=", content.split('guard let url = URL(string: "')[1].split('")')[0])
        self.assertNotIn("cachedContentServers", content)
        self.assertIn("https://steampipe.akamaized.net", content)
        self.assertIn("serverEligibility(server, appID: appID)", content)
        self.assertIn("Self.usableContentHost(host)", content)

    def test_login_directory_uses_ip_location_without_cell_override(self):
        self.assertIn(
            "GetCMListForConnect/v1/?cmtype=websockets",
            CM,
        )
        self.assertNotIn("GetCMListForConnect/v1/?cellid=0", CM)
        self.assertIn("loadCachedServers()", CM)

    def test_existing_live_download_ranking_and_authorization_remain(self):
        self.assertIn("ContentHostHealth()", DEPOT)
        self.assertIn("plan.health.order(plan.hosts, seed: seed)", DEPOT)
        self.assertIn("plan.health.recordSuccess(host", DEPOT)
        self.assertIn("plan.health.recordFailure(host)", DEPOT)
        self.assertIn("cdnAuthFragment(depotID:", DEPOT)

    def test_jit_pool_retries_are_bounded_and_debugger_protected(self):
        self.assertIn("384ULL * MiB", FEX)
        self.assertIn("256ULL * MiB", FEX)
        self.assertIn("192ULL * MiB", FEX)
        self.assertIn("128ULL * MiB", FEX)
        self.assertIn("96ULL * MiB", FEX)
        self.assertIn("64ULL * MiB", FEX)
        self.assertIn('if (!debugger_attached())', FEX)
        self.assertIn('vm_remap(mach_task_self()', FEX)
        self.assertIn("vm_deallocate(mach_task_self()", FEX)


if __name__ == "__main__":
    unittest.main()
