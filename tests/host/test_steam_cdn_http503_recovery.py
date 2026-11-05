import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEPOT = (ROOT / "iDeck/SwiftSteam/Content/DepotDownloader.swift").read_text(encoding="utf-8")


class SteamCDN503RecoveryTests(unittest.TestCase):
    def test_chunks_retry_temporary_cdn_outages_with_host_failover(self):
        self.assertIn("let maxAttempts = max(attempts, plan.hosts.count * 2, 10)", DEPOT)
        self.assertIn("let order = plan.health.order(plan.hosts, seed: seed)", DEPOT)
        self.assertIn("plan.health.recordFailure(host, reason: failureReason(error))", DEPOT)
        self.assertIn("status == 429 || (500...504).contains(status)", DEPOT)
        self.assertIn("let delay = overloaded", DEPOT)
        self.assertIn("try await Task.sleep(nanoseconds: delay)", DEPOT)

    def test_manifest_retries_transient_outages_without_bypassing_auth(self):
        self.assertIn("for round in 0..<3", DEPOT)
        self.assertIn("var transientOutage = false", DEPOT)
        self.assertIn("transientOutage = true", DEPOT)
        self.assertIn("manifestRequestCode(depotID: depotID", DEPOT)
        self.assertIn("status == 401 || status == 403", DEPOT)
        self.assertIn("throw SteamError.contentRefused(refusedStatus)", DEPOT)

    def test_download_integrity_and_cancel_are_unchanged(self):
        self.assertIn("try Task.checkCancellation()", DEPOT)
        self.assertIn("expectedCRC: chunk.crc", DEPOT)
        self.assertIn("plan.health.recordSuccess(host)", DEPOT)
        self.assertIn("try write(data, to: path, offset: chunk.offset)", DEPOT)
        self.assertIn("journal.append(key)", DEPOT)


if __name__ == "__main__":
    unittest.main()
