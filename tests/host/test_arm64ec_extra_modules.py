"""Wine modules the x64 farm lacked are built from the ARM64EC tree."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIST = ROOT / "scripts/arm64ec_extra_modules.txt"


def targets():
    return [line for line in LIST.read_text().splitlines() if line and not line.startswith("#")]


class ExtraModuleTests(unittest.TestCase):
    def test_targets_are_arm64ec_wine_targets(self):
        names = set()
        for target in targets():
            parts = target.split("/")
            self.assertEqual(len(parts), 4, target)
            self.assertIn(parts[0], ("dlls", "programs"))
            self.assertEqual(parts[2], "arm64ec-windows", target)
            names.add(parts[3])
        for needed in ("quartz.dll", "evr.dll", "advpack.dll", "devenum.dll", "msiexec.exe",
                       "rundll32.exe", "regsvr32.exe", "l3codecx.ax"):
            self.assertIn(needed, names)

    def test_nothing_madeira_owns_is_rebuilt(self):
        owned = {"d3d9.dll", "d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll", "ntdll.dll",
                 "xtajit64.dll", "d3d12.dll", "d3d12core.dll", "nvapi64.dll"}
        self.assertFalse(owned & {t.rsplit("/", 1)[1] for t in targets()})

    def test_built_after_cmd_and_keyed_in_the_kit_cache(self):
        components = (ROOT / "scripts/build_madeira_components.sh").read_text()
        self.assertLess(components.index('install -m 644 "$cmd_output"'),
                        components.index('done < "$ROOT/scripts/arm64ec_extra_modules.txt"'))
        self.assertIn('install -m 644 "$MD/wine/build-arm64ec/$target" "$MD/app/Madeira/arm64ec-windows/$name"', components)
        workflow = (ROOT / ".github/workflows/ios.yml").read_text()
        kit = next(line for line in workflow.splitlines() if "key: madeira-kit-" in line)
        self.assertIn("'scripts/arm64ec_extra_modules.txt'", kit)


if __name__ == "__main__":
    unittest.main()
