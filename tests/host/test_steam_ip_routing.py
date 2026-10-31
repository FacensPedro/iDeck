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
        self.assertNotIn('name: "cellid"', CM)
        # A cached ranked list is used at once and refreshed in the background.
        self.assertIn("static let shared = CMServerList()", CM)
        self.assertIn("refreshInBackground()", CM)
        self.assertIn("keeping cached servers", CM)

    def test_cm_connect_races_best_servers(self):
        self.assertIn("private static let raceWidth = 3", CM)
        self.assertIn("switch await Self.race(candidates, delegate: wsDelegate)", CM)
        self.assertIn("group.cancelAll()", CM)
        self.assertIn("request.timeoutInterval = Self.directoryTimeout", CM)

    def test_existing_live_download_ranking_and_authorization_remain(self):
        self.assertIn("ContentHostHealth()", DEPOT)
        self.assertIn("plan.health.order(plan.hosts, seed: seed)", DEPOT)
        self.assertIn("plan.health.recordSuccess(host", DEPOT)
        self.assertIn("plan.health.recordFailure(host)", DEPOT)
        self.assertIn("cdnAuthFragment(depotID:", DEPOT)

    def test_installation_pipeline_preserves_verification_and_retries(self):
        self.assertIn("SteamChunkScheduler.batches(paths: prepared.paths)", DEPOT)
        self.assertIn("var scheduler = SteamChunkScheduler(counts:", DEPOT)
        self.assertIn("while inFlight < capacity && enqueue()", DEPOT)
        self.assertIn("let journals = try prepared.journals.map", DEPOT)
        self.assertIn("try await checkExisting(plans: plans", DEPOT)
        self.assertIn("let written = try write(data, to: path, offset: chunk.offset)", DEPOT)
        self.assertNotIn("reuseExisting: verify", DEPOT)
        self.assertIn("ideck_steam_write_chunk(", DEPOT)
        self.assertIn("var createdDirectories = Set<String>()", DEPOT)
        self.assertIn("createdDirectories.insert(parent.path).inserted", DEPOT)
        self.assertIn("plan.health.recordFailure(host)", DEPOT)
        self.assertIn("let attempts = attemptsPerChunk", DEPOT)

    def test_jit_pool_retries_are_bounded_and_debugger_protected(self):
        self.assertIn("constexpr size_t allowed[] = {384, 256, 192, 128, 96, 64}", FEX)
        self.assertIn('sysctlbyname("hw.memsize"', FEX)
        self.assertIn("if (candidate <= preferred) sizes.push_back(candidate * MiB);", FEX)
        self.assertIn("for (size_t size : wine_pool_candidates())", FEX)
        self.assertIn('getenv("IDECK_WINE_JIT_MIB")', FEX)
        self.assertIn('if (!debugger_attached())', FEX)
        self.assertIn('vm_remap(mach_task_self()', FEX)
        self.assertIn("vm_deallocate(mach_task_self()", FEX)


if __name__ == "__main__":
    unittest.main()
