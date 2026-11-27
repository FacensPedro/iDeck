"""Microsoft's D3DX 9 for games whose shaders Wine's D3DX cannot compile."""
import split_sources  # noqa: F401  (iDeck 3.0 split files)
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ENV = (ROOT / "iDeck/WindowsInstallerEnvironment.swift").read_text()
COORDINATOR = (ROOT / "iDeck/SystemCoordinator.swift").read_text()


class NativeD3DXTests(unittest.TestCase):
    def test_official_runtime_only(self):
        self.assertIn('https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe', ENV)
        self.assertIn("VisualCRuntimeBootstrap.isTrustedDownloadURL(final)", ENV)
        self.assertIn('static let modules: [String] = (24...43).map { "d3dx9_\\($0)" } + (33...43).map { "d3dcompiler_\\($0)" }', ENV)

    def test_per_program_override_and_placement(self):
        self.assertIn('let key = "Software\\\\Wine\\\\AppDefaults\\\\" + executable.lastPathComponent + "\\\\DllOverrides"', ENV)
        self.assertIn('data: .string("native,builtin")', ENV)
        self.assertIn("guard wine_process_is_running() == 0, wineserver_is_running() == 0 else {", ENV)

    def test_shader_failure_marks_the_program(self):
        self.assertIn("let shaderFailure = Self.sessionLogShowsShaderFailure(logURL: Self.wineLogURL, since: wineLogStartOffset)", COORDINATOR)
        self.assertIn("NativeD3DX.noteShaderFailure(executable)", COORDINATOR)
        self.assertIn("let d3dx = NativeD3DX.wanted(executable) && !NativeD3DX.installed(for: executable)", COORDINATOR)
        sample = r'0088:trace:file:CreateFileW L"C:\\users\\mobile\\AppData\\Roaming\\Bioshock\\ShaderErrors\\CompileError00001.hlsl"'
        self.assertIn("\\\\ShaderErrors\\\\CompileError", sample)

    def test_extractor_allows_the_runtime_cabs(self):
        self.assertIn("#define MAX_NESTED_CABS 200u", (ROOT / "iDeck/NativeRuntime/VCArchiveExtractor.c").read_text())


if __name__ == "__main__":
    unittest.main()
