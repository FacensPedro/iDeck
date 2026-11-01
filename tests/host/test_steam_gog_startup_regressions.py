"""Host checks for GOG signed CDN retries and Steam runtime preparation races."""
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
GOG = ROOT / "iDeck/GOGContentSystem.swift"
STEAM = ROOT / "iDeck/MadeiraDock.swift"
COORD = ROOT / "iDeck/SystemCoordinator.swift"


class SteamSetupAndGOGCDNTests(unittest.TestCase):
    def test_steam_concurrent_requests_share_one_operation(self):
        source = STEAM.read_text(encoding="utf-8")
        self.assertIn("private var inFlight: Task<Void, Error>?", source)
        self.assertIn("if let running = inFlight {", source)
        self.assertIn("try await running.value", source)
        self.assertIn("inFlightPrefix == path", source)
        self.assertIn("try await operation.value", source)
        self.assertIn("private func prepareOnce(", source)
        self.assertNotIn("guard !busy, !ideck_wineprocess_running()", source)
        self.assertIn("ideck_wineserver_stop_if_idle()", source)
        # No attempt to change registry while Wine is running.
        self.assertIn("guard !ideck_wineprocess_running(), !ideck_wineserver_running() else", source)

    def test_gog_rotates_providers_and_never_retries_cancellation(self):
        source = GOG.read_text(encoding="utf-8")
        self.assertIn('let providers: [SignedCDN] = urls.compactMap', source)
        self.assertIn('attempt % choices.count', source)
        self.assertIn('let exhausted = attempt > 0', source)
        self.assertIn('await linkCache.store(entry, for: productID)', source)
        self.assertIn('Self.md5(data) == chunk.compressedMd5.lowercased()', source)
        self.assertIn('catch let error as URLError where error.code == .cancelled', source)
        self.assertIn('throw CancellationError()', source)
        self.assertIn('try Task.checkCancellation()', source)
        self.assertNotIn('lock.lock()', source)
        self.assertIn('request.setValue("Bearer " + tokens.accessToken', source)

    def test_signed_url_formatter_with_swift(self):
        swiftc = shutil.which("swiftc")
        if swiftc is None:
            self.skipTest("Swift compiler is unavailable")
        source = GOG.read_text(encoding="utf-8")
        url_function = source.split("    static func signedChunkURL(", 1)[1].split("\n    static func galaxyPath(", 1)[0]
        galaxy_function = source.split("    static func galaxyPath(", 1)[1].split("\n    /// zlib", 1)[0]
        snippet = (
            "import Foundation\n"
            "enum GOGContentSystem {\n"
            "    static func signedChunkURL(" + url_function
            + "    static func galaxyPath(" + galaxy_function + "\n}\n"
        )
        main = r'''
@main struct Check {
    static func require(_ ok: Bool, _ msg: String) {
        if !ok { fatalError(msg) }
    }
    static func main() {
        let hash = "00112233445566778899aabbccddeeff"
        let template = "https://cdn.example.test/signed/{token}{path}"
        let url = GOGContentSystem.signedChunkURL(
            format: template,
            parameters: ["token": "abc", "path": "/content-system/v2/store/123/"],
            hash: hash)
        require(url?.absoluteString ==
            "https://cdn.example.test/signed/abc/content-system/v2/store/123/00/11/" + hash,
            "must use exactly one slash between store directory and chunk")
        let root = GOGContentSystem.signedChunkURL(
            format: "https://cdn.example.test/{path}",
            parameters: ["path": "/"], hash: hash)
        require(root?.absoluteString == "https://cdn.example.test/00/11/" + hash,
                "root path must not contain duplicated slashes")
        require(GOGContentSystem.signedChunkURL(format: "http://cdn.example.test/{path}",
            parameters: [:], hash: hash) == nil, "reject insecure CDN")
        require(GOGContentSystem.signedChunkURL(format: template,
            parameters: ["path": "/"], hash: "not-a-valid-md5") == nil, "reject invalid md5")
        require(GOGContentSystem.signedChunkURL(format: template,
            parameters: ["path": "/"], hash: hash) == nil, "reject unresolved placeholders")
        print("PASS: GOG signed CDN paths are canonical and HTTPS only")
    }
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            file = pathlib.Path(tmp) / "CDNTests.swift"
            exe = pathlib.Path(tmp) / "cdn-tests"
            file.write_text(snippet + main, encoding="utf-8")
            result = subprocess.run(
                [swiftc, "-parse-as-library", "-swift-version", "5", str(file), "-o", str(exe)],
                capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=20)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
