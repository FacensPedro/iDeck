import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECK = (ROOT / "iDeck/SessionCompatibility.swift").read_text()
ENV = (ROOT / "iDeck/WindowsEnvironment.swift").read_text()
COORD = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
REPORT = (ROOT / "iDeck/BugReportView.swift").read_text()


class DependencyCheckTests(unittest.TestCase):
    def test_reads_pe32_and_pe32plus_import_tables(self):
        self.assertIn("let directories = optional + (magic == 0x20B ? 112 : 96)", CHECK)
        self.assertIn("let importRVA = u32(directories + 8)", CHECK)

    def test_architectures(self):
        self.assertIn('case 0x014C: return "i386-windows"', CHECK)
        self.assertIn('case 0x8664, 0xA641, 0xAA64: return "arm64ec-windows"', CHECK)
        self.assertIn("case 0x014C: return library == 0x014C", CHECK)
        self.assertIn('.appendingPathComponent(machine == 0x014C ? "syswow64" : "system32")', CHECK)

    def test_game_folder_first_and_shipped_dlls_followed(self):
        self.assertIn("if let local = localNames[name] {", CHECK)
        self.assertIn("result.wrongArchitecture.append(local.lastPathComponent)", CHECK)
        self.assertIn("queue.append(contentsOf: libraryInfo.imports)", CHECK)
        self.assertIn('"api-ms-"', CHECK)

    def test_relative_path_imports_resolve_in_the_game_folder(self):
        # 2.15.0 reported "missing core/activation64.dll" for Dragon Age: Inquisition,
        # whose program imports Core\Activation64.dll by a path relative to itself.
        self.assertIn('if localFile == nil, name.contains("\\\\") || name.contains("/") {', CHECK)
        self.assertIn(".first(where: { $0.lowercased() == part })", CHECK)

    def test_runs_at_launch_and_explains_an_early_end(self):
        self.assertIn("DependencyCheck.run(program: binary, prefix: MadeiraDock.prefix)", ENV)
        self.assertIn('outcome.reason += " DLL check before the start: " + check.summary + "."', COORD)
        self.assertIn("outcome.ntstatus == 0xC0000135 || outcome.ntstatus == 0xC000007B", COORD)
        self.assertIn('lines.append("DLL check: " + deps)', REPORT)


if __name__ == "__main__":
    unittest.main()
