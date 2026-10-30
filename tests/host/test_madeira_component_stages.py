import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COMPONENTS = ROOT / "scripts/build_madeira_components.sh"


class MadeiraComponentStageTests(unittest.TestCase):
    def test_component_stage_build_script_has_valid_bash_syntax(self):
        subprocess.run(["bash", "-n", str(COMPONENTS)], check=True)

    def test_component_stages_have_explicit_success_gates(self):
        source = COMPONENTS.read_text()
        self.assertIn('IDECK_MADEIRA_STOP_AFTER:-all', source)
        self.assertIn('STOP_AFTER" == "fex"', source)
        self.assertIn('STOP_AFTER" == "wine"', source)
        self.assertIn('IDECK_MADEIRA_REBUILD=1', source)
        self.assertIn('required FEX output not compiled', source)
        self.assertIn('required Wine ARM64EC output not compiled', source)
        self.assertIn('libwineserver.a', source)
        self.assertIn('libntdll_unix.a', source)
        self.assertIn('libwin32u_unix.a', source)
        self.assertIn('xtajit64.dll', source)
        self.assertIn('libFEXCore.a', source)

    def test_graphics_build_must_not_run_before_fex_or_wine_gate(self):
        source = COMPONENTS.read_text()
        fex_start = source.index('bash "$MD/build/fex-arm64ec/build.sh"')
        fex_gate = source.index('if [[ "$STOP_AFTER" == "fex" ]]', fex_start)
        wine_start = source.index('bash "$MD/build/wineserver/build.sh"')
        wine_gate = source.index('if [[ "$STOP_AFTER" == "wine" ]]', wine_start)
        dxmt_build = source.index('bash "$MD/build/dxmt-ios/build.sh"')
        self.assertLess(fex_start, fex_gate)
        self.assertLess(fex_gate, wine_start)
        self.assertLess(wine_start, wine_gate)
        self.assertLess(wine_gate, dxmt_build)

    def test_d3d12_remains_optional_and_licensed(self):
        source = COMPONENTS.read_text()
        self.assertIn('if [[ "$GRAPHICS" == "d3d12" ]]; then', source)
        self.assertIn('bash "$MD/build/madeira-d3d12/build-pe.sh"', source)
        self.assertIn('IDECK_BUILD_WOW64 must be 0 or 1', source)
        self.assertIn('bash "$MD/build/fex-wow64/build.sh"', source)
        self.assertIn('bash "$MD/build/wine-i386/build.sh"', source)


if __name__ == "__main__":
    unittest.main()
