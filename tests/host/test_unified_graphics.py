"""Unified D3D11 + D3D12 IPA: profile plumbing and the PE graphics-API scanner."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOOLS = all(shutil.which(tool) for tool in ("clang", "lld-link", "cc"))


@unittest.skipUnless(TOOLS, "needs clang and lld-link to build Windows test executables")
class GraphicsAPIScanTests(unittest.TestCase):
    """Builds real PE files with import and delay-import tables and checks the C scanner."""

    @classmethod
    def setUpClass(cls):
        cls.dir = pathlib.Path(tempfile.mkdtemp())
        d = cls.dir
        for dll in ("d3d12", "d3d11", "dxgi"):
            (d / f"{dll}.def").write_text(f"LIBRARY {dll}.dll\nEXPORTS\n  F_{dll}\n")
            subprocess.run(["lld-link", "/lib", f"/def:{d}/{dll}.def", f"/out:{d}/{dll}.lib", "/machine:x64"],
                           check=True, capture_output=True)
        sources = {
            "static12": "void F_d3d12(void); void F_dxgi(void); int mainCRTStartup(void){F_d3d12();F_dxgi();return 0;}",
            "hybrid": "void F_d3d11(void); static const unsigned short w[]={'D','3','D','1','2','.','D','L','L',0};"
                      "const void * volatile k=w; int mainCRTStartup(void){F_d3d11();return 0;}",
            "none": "int mainCRTStartup(void){return 0;}",
            "delay12": "void F_d3d12(void); void *__delayLoadHelper2(const void*a, void**f){(void)a;return *f;}"
                       "int mainCRTStartup(void){F_d3d12();return 0;}",
        }
        for name, code in sources.items():
            (d / f"{name}.c").write_text(code)
            subprocess.run(["clang", "--target=x86_64-pc-windows-msvc", "-c", f"{d}/{name}.c", "-o", f"{d}/{name}.obj"], check=True)
            extra = ["/delayload:d3d12.dll"] if name == "delay12" else []
            subprocess.run(["lld-link", "/entry:mainCRTStartup", "/subsystem:console", "/nodefaultlib", *extra,
                            f"/out:{d}/{name}.exe", f"{d}/{name}.obj", f"{d}/d3d12.lib", f"{d}/d3d11.lib", f"{d}/dxgi.lib"],
                           check=True, capture_output=True)
        (d / "main.c").write_text('#include <stdio.h>\n#include "GraphicsAPIScan.h"\n'
                                  'int main(int c,char**v){for(int i=1;i<c;i++)printf("%u\\n",ideck_pe_graphics_apis(v[i]));}')
        subprocess.run(["cc", "-std=gnu11", "-Wall", "-Wextra", "-Werror", f"-I{ROOT}/iDeck", f"{d}/main.c",
                        f"{ROOT}/iDeck/GraphicsAPIScan.c", "-o", f"{d}/scan"], check=True)

    def scan(self, name):
        out = subprocess.run([f"{self.dir}/scan", f"{self.dir}/{name}"], check=True, capture_output=True, text=True)
        value = int(out.stdout.strip())
        return value & 0xFFFF, value >> 16

    def test_static_imports(self):
        self.assertEqual(self.scan("static12.exe"), (0x08 | 0x10, 0x08 | 0x10))   # D3D12 + DXGI, both imported

    def test_dynamic_load_string_is_seen_but_not_called_static(self):
        apis, static = self.scan("hybrid.exe")
        self.assertEqual(apis, 0x04 | 0x08)      # D3D11 imported, D3D12 named in UTF-16 text
        self.assertEqual(static, 0x04)

    def test_delay_imports_count_as_static(self):
        self.assertEqual(self.scan("delay12.exe"), (0x08, 0x08))

    def test_no_api_and_unreadable(self):
        self.assertEqual(self.scan("none.exe"), (0, 0))
        self.assertEqual(self.scan("missing.exe"), (0, 0))


class UnifiedProfileTests(unittest.TestCase):
    def test_build_accepts_unified_and_keeps_individual_profiles(self):
        build = (ROOT / "scripts/build_ipa.sh").read_text()
        self.assertIn('export IDECK_GRAPHICS_PROFILE="${IDECK_GRAPHICS_PROFILE:-${IDECK_MADEIRA_GRAPHICS:-unified}}"', build)
        self.assertIn("unified|d3d12) export IDECK_MADEIRA_GRAPHICS=d3d12 ;;", build)
        self.assertIn("d3d11) export IDECK_MADEIRA_GRAPHICS=d3d11 ;;", build)
        for script in ("stage_madeira_payload.sh", "link_madeira_native.sh", "build_madeira_components.sh"):
            self.assertIn('[[ "$GRAPHICS" == "unified" ]] && GRAPHICS=d3d12', (ROOT / "scripts" / script).read_text())

    def test_manifest_records_each_backend(self):
        verify = (ROOT / "scripts/verify_madeira_bundle.py").read_text()
        self.assertIn('"d3d11Available": True,', verify)
        self.assertIn('"d3d12Available": options.graphics == "d3d12",', verify)
        self.assertIn('"graphicsProfile": graphics_profile(options),', verify)

    def test_workflow_defaults_to_unified_and_checks_both_backends(self):
        workflow = (ROOT / ".github/workflows/ios.yml").read_text()
        self.assertIn("options: [unified, d3d11, d3d12]", workflow)
        self.assertIn("inputs.graphics_profile || 'unified'", workflow)
        self.assertIn('flags.get("d3d11Available") is not True', workflow)

    def test_api_preference_uses_engine_switch_never_translation(self):
        env = (ROOT / "iDeck/WindowsEnvironment.swift").read_text()
        self.assertIn('return preferD3D12 ? "-force-d3d12" : "-force-d3d11"', env)
        self.assertIn('return preferD3D12 ? "-dx12" : "-dx11"', env)
        self.assertNotIn("IDECK_PREFERRED_GRAPHICS_API", env)
        self.assertIn("ideck_pe_graphics_apis", env)

    def test_direct3d_choice_is_automatic(self):
        env = (ROOT / "iDeck/WindowsEnvironment.swift").read_text()
        self.assertIn("guard d3d11 && d3d12 else {", env)
        self.assertIn("guard !d3d12Available else {", env)
        self.assertIn("Self.engineAPIArgument(binary: binary, preferD3D12: false)", env)
        self.assertNotIn("sessionGraphicsAPI", env)
        view = (ROOT / "iDeck/MainView.swift").read_text()
        self.assertNotIn('DetailPickerRow(title: tr("Graphics API")', view)
        models = (ROOT / "iDeck/WindowsLibraryModels.swift").read_text()
        self.assertIn('static func normalizedGraphicsAPI(_ stored: String?) -> String { "Automatic" }', models)


if __name__ == "__main__":
    unittest.main()
