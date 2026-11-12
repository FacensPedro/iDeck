"""EA range requests are gated before they reach URLSession."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EA = (ROOT / "iDeck/Vendor/Madeira/SwiftEA/EADownloader.swift").read_text()
SPEED = (ROOT / "iDeck/DownloadSpeed.swift").read_text()


class EADownloadGateTests(unittest.TestCase):
    def test_fewer_requests_in_flight_than_connections(self):
        def value(name):
            line = next(l for l in SPEED.splitlines() if f"static let {name} = " in l)
            return int(line.split("=")[1])
        self.assertLess(value("eaRangeRequests"), value("eaConnections"))
        # Without the gate, files x segments is what URLSession would be handed.
        self.assertGreater(value("eaFiles") * value("eaSegments"), value("eaConnections"))

    def test_bytes_waits_at_the_gate_and_always_releases(self):
        body = EA[EA.index("    func bytes(_ url: URL, range: Range<Int64>) async throws -> Data {"):]
        body = body[:body.index("\n    }\n")]
        self.assertLess(body.index("await gate.acquire()"), body.index("http.data(for: request"))
        self.assertEqual(body.count("await gate.release()"), 2)  # failure and success
        self.assertIn("request.timeoutInterval = 30", body)
        self.assertIn("try Task.checkCancellation()", body)

    def test_gate_hands_a_released_slot_to_the_next_waiter(self):
        gate = EA[EA.index("actor EARangeGate {"):EA.index("/// Reading from EA's CDN by byte range.")]
        self.assertIn("if waiters.isEmpty { free += 1 } else { waiters.removeFirst().resume() }", gate)

    def test_delegate_thread_is_not_held_for_half_a_minute(self):
        self.assertIn("let deadline = Date().addingTimeInterval(5)", EA)
        self.assertNotIn("addingTimeInterval(30)", EA)


if __name__ == "__main__":
    unittest.main()
