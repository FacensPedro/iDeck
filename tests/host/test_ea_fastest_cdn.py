import unittest

from support import repo_text

DOWNLOADER = repo_text("iDeck/Vendor/Madeira/SwiftEA/EADownloader.swift")


class EAFastestCDNTests(unittest.TestCase):
    def test_mirrors_are_probed_and_checked_before_use(self):
        self.assertIn("func fastestMirror(for url: URL, size: Int64) async -> URL", DOWNLOADER)
        self.assertIn('reply.statusCode == 206', DOWNLOADER)
        self.assertIn('hasSuffix("/\\\\(size)")', DOWNLOADER)
        self.assertIn("guard let best = timings.min(by: { $0.1 < $1.1 }) else { return url }", DOWNLOADER)
        self.assertIn("archive = await downloader.fastestMirror(archive)", repo_text("iDeck/EALibrary.swift"))

    def test_six_files_at_once(self):
        self.assertIn("private let parallel = 6", DOWNLOADER)


if __name__ == "__main__":
    unittest.main()
