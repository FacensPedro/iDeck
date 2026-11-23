"""Why Ubisoft's download service does not answer goes to the log (2.13.3).

iPad mini, 2026-11-23: "O serviço de download da Ubisoft não respondeu (connection)"
after 20 s, with nothing else to tell DNS, a refused port or TLS apart.
"""
from __future__ import annotations

import pathlib
import unittest

SRC = (pathlib.Path(__file__).resolve().parents[2] / "iDeck" / "UbisoftDownloader.swift").read_text()


class DemuxDiagnosticsTests(unittest.TestCase):
    def open_body(self) -> str:
        start = SRC.index("private func open(ipv4Only: Bool, tls12: Bool = false) async throws -> NWConnection {")
        return SRC[start:SRC.index("\n    }\n", SRC.index("return connection", start))]

    def test_two_attempts_the_second_over_ipv4(self):
        self.assertIn("for attempt in 1...3 {", SRC)
        self.assertIn("opened = try await open(ipv4Only: attempt == 3, tls12: attempt >= 2)", SRC)
        self.assertIn("ip.version = .v4", self.open_body())
        self.assertIn("sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)", self.open_body())

    def test_states_and_reasons_logged(self):
        body = self.open_body()
        for line in ('"[ubisoft-demux] connecting (', 'reason = "waiting: \\(error.localizedDescription)"',
                     '"[ubisoft-demux] connected (', '"[ubisoft-demux] failed: '):
            self.assertIn(line, body)
        self.assertIn('UbisoftDemuxError.timeout("connection, \\(reason)")', body)

    def test_failed_attempt_does_not_poison_the_next(self):
        body = self.open_body()
        self.assertIn("else { self?.queue.async { self?.fail(error) } }", body)

    def test_no_address_in_the_log(self):
        body = self.open_body()
        self.assertNotIn("remoteEndpoint", body)


if __name__ == "__main__":
    unittest.main()
