import unittest

from support import repo_text


class ArtworkLoaderTests(unittest.TestCase):
    def test_covers_load_with_cache_and_priority(self):
        loader = repo_text("iDeck/ArtworkLoader.swift")
        self.assertIn("task.priority = URLSessionTask.highPriority", loader)
        self.assertIn("config.networkServiceType = .responsiveData", loader)
        self.assertIn("URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20", loader)
        project = repo_text("iDeck.xcodeproj/project.pbxproj")
        self.assertIn("/* ArtworkLoader.swift in Sources */", project)
        view = repo_text("iDeck/MainView.swift")
        self.assertIn("ArtworkImage(url: urls[index], failed: { index += 1 })", view)
        self.assertIn("ArtworkImage(url: urls[imageIndex], failed: { imageIndex += 1 })", view)

    def test_ea_ranges_yield(self):
        downloader = repo_text("iDeck/Vendor/Madeira/SwiftEA/EADownloader.swift")
        self.assertIn("task.priority = URLSessionTask.lowPriority", downloader)
        self.assertIn("http.data(for: request, delegate: LowPriority.shared)", downloader)


if __name__ == "__main__":
    unittest.main()
