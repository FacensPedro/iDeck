import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/ios.yml").read_text()


class IpaSizeTests(unittest.TestCase):
    def test_mono_bundled_and_vcruntime_downloaded_on_device(self):
        line = next(l for l in WORKFLOW.splitlines() if l.strip().startswith("IDECK_BUNDLE_WINE_MONO:"))
        # Wine Mono is never in the IPA; the initial setup installs it.
        self.assertEqual(line.strip(), "IDECK_BUNDLE_WINE_MONO: '0'")
        self.assertIn("IDECK_BUNDLE_VCRUNTIME: '0'", WORKFLOW)
        self.assertIn("IDECK_SPLIT_RUNTIME: '0'", WORKFLOW)
        self.assertIn('static let downloadURL = URL(string: "https://aka.ms/vc14/vc_redist.x64.exe")!',
                      (ROOT / "iDeck/VisualCRuntimeBootstrap.swift").read_text())


if __name__ == "__main__":
    unittest.main()
