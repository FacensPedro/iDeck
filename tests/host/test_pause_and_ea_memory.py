import unittest

from support import repo_text

EA_DOWNLOADER = repo_text("iDeck/Vendor/Madeira/SwiftEA/EADownloader.swift")
EA = repo_text("iDeck/EALibrary.swift")
EPIC = repo_text("iDeck/EpicLibrary.swift")


class PauseAndEAMemoryTests(unittest.TestCase):
    def test_ea_stream_has_back_pressure(self):
        self.assertIn("struct EARangeStream: AsyncSequence", EA_DOWNLOADER)
        self.assertIn("task?.suspend()", EA_DOWNLOADER)
        self.assertIn("task?.resume()", EA_DOWNLOADER)
        self.assertIn("flow.consumed(chunk.count)", EA_DOWNLOADER)
        self.assertIn("try Task.checkCancellation()\n            guard let chunk = try await inner.next()", EA_DOWNLOADER)

    def test_pause_shows_paused_at_once(self):
        for source in (EA, EPIC):
            pause = source.split("func pause(", 1)[1].split("\n    }\n", 1)[0]
            self.assertIn("current.task.cancel()", pause)
            self.assertIn("?.state = .paused", pause.split("current.task.cancel()", 1)[1].split("} else", 1)[0])


if __name__ == "__main__":
    unittest.main()
