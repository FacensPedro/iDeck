"""The x64 (ARM64EC) Wine farm: Madeira's prebuilt one by default, rebuilt on request."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COMPONENTS = (ROOT / "scripts/build_madeira_components.sh").read_text()


class X64FarmRebuildTests(unittest.TestCase):
    def test_rebuild_is_opt_in(self):
        self.assertIn('if [[ "${IDECK_REBUILD_WINE_PE_MODULES:-0}" == "1" ]]; then', COMPONENTS)
        self.assertNotIn('IDECK_REBUILD_WINE_PE_MODULES:-1', COMPONENTS)
        self.assertIn('done < <(python3 "$MD/build/windows-runtime/targets.py" arm64ec list)', COMPONENTS)
        self.assertIn('bash "$MD/build/wine-pe/build-modules.sh" "${X64_MODULES[@]}"', COMPONENTS)
        self.assertIn('[[ "$module" == d3d9-wined3d ]]', COMPONENTS)
        self.assertIn('"$module" != ntdll', COMPONENTS)

    def test_rebuilt_after_ntdll_and_before_the_extra_modules(self):
        ntdll = COMPONENTS.index('bash "$MD/build/wine-pe/build-ntdll.sh"')
        rebuild = COMPONENTS.index('"${X64_MODULES[@]}"')
        extra = COMPONENTS.index('done < "$ROOT/scripts/arm64ec_extra_modules.txt"')
        self.assertLess(ntdll, rebuild)
        self.assertLess(rebuild, extra)

    def test_patches_are_applied_before_any_build(self):
        fetch = (ROOT / "scripts/fetch_madeira_sources.sh").read_text()
        self.assertIn('python3 "$ROOT/scripts/apply_madeira_wine_compat.py" "$DEST"', fetch)

    def test_extra_dlls_go_through_build_modules_for_undelay(self):
        loop = COMPONENTS[COMPONENTS.index("EXTRA_FAILED=()"):COMPONENTS.index('done < "$ROOT/scripts/arm64ec_extra_modules.txt"')]
        self.assertIn('if [[ "$target" == dlls/* ]]; then', loop)
        self.assertIn('bash "$MD/build/wine-pe/build-modules.sh" "$directory"', loop)


if __name__ == "__main__":
    unittest.main()
