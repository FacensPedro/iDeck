import unittest

from support import repo_text

DOWNLOADER = repo_text("iDeck/Vendor/Madeira/SwiftEA/EADownloader.swift")


class EAFastestCDNTests(unittest.TestCase):
    def test_mirrors_are_probed_and_checked_before_use(self):
        self.assertIn("func fastestMirror(for url: URL, size: Int64) async -> URL", DOWNLOADER)
        self.assertIn('reply.statusCode == 206', DOWNLOADER)
        self.assertIn('hasSuffix("/\\(size)")', DOWNLOADER)
        self.assertIn("guard let best = timings.min(by: { $0.1 < $1.1 }) else { return url }", DOWNLOADER)
        self.assertIn("archive = await downloader.fastestMirror(archive)", repo_text("iDeck/EALibrary.swift"))

    def test_six_files_at_once(self):
        self.assertIn("private let parallel = 6", DOWNLOADER)


class EAMemoryTests(unittest.TestCase):
    def test_delivery_waits_past_the_hard_limit_and_is_released(self):
        self.assertIn("static let hardLimit = 24 << 20", DOWNLOADER)
        self.assertIn("while waiting > EARangeStream.hardLimit && !finished {", DOWNLOADER)
        self.assertIn("continuation.onTermination = { _ in flow.finish(); task.cancel() }", DOWNLOADER)
        self.assertIn("try autoreleasepool { try handle.write(contentsOf: out) }", DOWNLOADER)


class EASegmentedTests(unittest.TestCase):
    def test_large_files_download_in_parallel_ranges_like_steam(self):
        self.assertIn("static let segmentedThreshold: Int64 = 16 << 20", DOWNLOADER)
        self.assertIn("static let segmentsAtOnce = DownloadSpeed.steamChunks", DOWNLOADER)
        self.assertIn("if entry.compressedSize >= segmentedThreshold {", DOWNLOADER)
        self.assertIn("inflater.crc.checksum == entry.crc32", DOWNLOADER.split("private static func fetchSegmented", 1)[1])
        self.assertIn("config.httpMaximumConnectionsPerHost = 16", DOWNLOADER)


class EANativeInflateTests(unittest.TestCase):
    def test_apple_decoder_first_with_checked_fallback(self):
        self.assertIn("compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)", DOWNLOADER)
        self.assertIn("for useNative in [true, false] where !inflatedOK {", DOWNLOADER)
        self.assertIn("native: attempt == 1", DOWNLOADER)
        crc = repo_text("iDeck/Vendor/Madeira/SwiftEA/EAFormats.swift")
        self.assertIn("data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in", crc)


if __name__ == "__main__":
    unittest.main()
