"""iDeck 3.0.1: FNV in-game c000001D, DOOM (2016) on Vulkan, Mafia DE without 2K's launcher,
the whole EA activation log."""
import split_sources  # noqa: F401  (iDeck 3.0 split files)
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(rel):
    return (ROOT / rel).read_text()


class ReadVirtualMemorySafe(unittest.TestCase):
    def test_patch_in_series(self):
        self.assertIn("early     .      madeira-read-virtual-memory-safe.patch", read("patches/series.txt"))

    def test_current_process_read_goes_through_the_kernel(self):
        patch = read("patches/madeira-read-virtual-memory-safe.patch")
        self.assertIn("+++ b/build/ntdll-unix/virtual_ios.c", patch)
        self.assertIn("-            memmove( buffer, addr, size );", patch)
        self.assertIn("+        if (!size || mach_vm_read_overwrite( mach_task_self(), (mach_vm_address_t)addr, size,", patch)
        self.assertIn("+            size = done;", patch)


class DoomVulkanBuild(unittest.TestCase):
    def test_vulkan_build_replaces_the_opengl_exe(self):
        graphics = read("iDeck/Runtime/WindowsEnvironment+Graphics.swift")
        self.assertIn('static let vulkanBuilds: [String: String] = ["doomx64.exe": "DOOMx64vk.exe"]', graphics)
        self.assertIn('guard vulkanMode != "Off", runtime,', graphics)
        env = (ROOT / "iDeck/WindowsEnvironment.swift").read_text()
        self.assertIn("func execute(binary requestedBinary: URL,", env)
        self.assertIn("let binary = vulkanBuild ?? requestedBinary", env)


class GOGPublisherLauncher(unittest.TestCase):
    def test_mafia_direct_executable(self):
        gog = split_sources._original_read_text(ROOT / "iDeck/GOGLibrary.swift")
        self.assertIn('[1993581340: "mafiadefinitiveedition.exe"]', gog)
        self.assertIn('"launcher.exe"', gog)
        self.assertIn("if let primary, isPublisherLauncher(primary[\"path\"] as? String),", gog)
        self.assertIn('["setup", "config", "setting", "tool", "editor", "unins"]', gog)


class EAActivationRows(unittest.TestCase):
    def test_only_style_rules_are_dropped(self):
        report = split_sources._original_read_text(ROOT / "iDeck/BugReportView.swift")
        self.assertIn('let style = text.contains("{") || text.contains("}")', report)


if __name__ == "__main__":
    unittest.main()
