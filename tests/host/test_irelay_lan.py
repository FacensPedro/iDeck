import unittest

from support import repo_text


class IRelayLocalNetworkTests(unittest.TestCase):
    def test_service_listens_on_local_network_with_pairing_code(self):
        service = repo_text("iDeck/IRelayDeviceService.swift")
        self.assertNotIn("requiredInterfaceType = .loopback", service)
        self.assertIn("parameters.prohibitedInterfaceTypes = [.cellular]", service)
        self.assertIn('IRelayPairing.authorize(request.headers["x-ideck-code"], from: peer)', service)
        self.assertIn('request.method == "GET" && request.path == "/info"', service)
        self.assertIn("SecRandomCopyBytes", service)
        self.assertIn("entry.count >= 5", service)

    def test_tunnel_requires_pairing_preamble_and_keeps_local_port_on_loopback(self):
        client = repo_text("iDeck/IRelayClient.swift")
        self.assertNotIn("IRelayUSBTunnel", client)
        self.assertIn('text.hasPrefix("IRELAY ")', client)
        self.assertIn("if port == Self.localPort { parameters.requiredInterfaceType = .loopback }", client)
        self.assertIn("IRelayPairing.display", client)

    def test_settings_reports_listener_and_missing_pc_tunnel(self):
        client = repo_text("iDeck/IRelayClient.swift")
        service = repo_text("iDeck/IRelayDeviceService.swift")
        self.assertIn("Button(tr(\"Refresh connection\"))", client)
        self.assertNotIn('tr("iDeck service")', client)
        self.assertIn("guard IRelayTunnel.shared.pcConnected else", client)
        self.assertIn("case .ready: self.listenerState", service)
        self.assertIn("case .waiting(let error): self.listenerState", service)
        self.assertIn("case .failed(let error):", service)

    def test_four_digit_code_and_listener_without_bonjour(self):
        client = repo_text("iDeck/IRelayClient.swift")
        service = repo_text("iDeck/IRelayDeviceService.swift")
        self.assertIn("static let digits = 4", service)
        self.assertIn("preambleLength = 7 + IRelayPairing.digits + 1", client)
        self.assertNotIn("listener.service =", service)
        self.assertIn('NWBrowser(for: .bonjour(type: "_ideck._tcp", domain: nil)', service)
        self.assertIn("UIApplication.didBecomeActiveNotification", client)
        self.assertIn("IRelayDeviceService.shared.restartIfStopped()", client)
        self.assertIn("IRelayTunnel.shared.restartIfStopped()", client)

    def test_no_usb_transport_left(self):
        for path in ("iDeck/IRelayClient.swift", "iDeck/IRelayDeviceService.swift"):
            text = repo_text(path)
            self.assertNotIn("usbmux", text)
            self.assertNotIn("USB cable", text)


if __name__ == "__main__":
    unittest.main()
