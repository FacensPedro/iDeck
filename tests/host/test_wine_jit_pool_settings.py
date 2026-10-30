import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class WineJITPoolSettingsTests(unittest.TestCase):
    def test_native_pool_sizes_are_exactly_the_supported_set(self):
        native = (ROOT / "iDeck/NativeRuntime/FEXRuntime.cpp").read_text()
        self.assertIn("constexpr size_t allowed[] = {384, 256, 192, 128, 96, 64}", native)
        self.assertIn('getenv("IDECK_WINE_JIT_MIB")', native)
        self.assertIn('ignored unsupported IDECK_WINE_JIT_MIB', native)

    def test_ui_and_coordinator_only_accept_supported_sizes(self):
        coordinator = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
        ui = (ROOT / "iDeck/SettingsView.swift").read_text()
        self.assertIn("private static let supportedWineJITPoolMiB: Set<Int> = [64, 96, 128, 192, 256, 384]", coordinator)
        self.assertIn('setenv("IDECK_WINE_JIT_MIB", String(sizeMiB), 1)', coordinator)
        self.assertIn('unsetenv("IDECK_WINE_JIT_MIB")', coordinator)
        self.assertIn('UserDefaults.standard.integer(forKey: "wineJITPoolMiB")', coordinator)
        self.assertIn("guard !wineJITPreparationInFlight && !ideck_wine_jit_pool_ready()", coordinator)
        self.assertIn("@AppStorage(\"wineJITPoolMiB\")", ui)
        self.assertIn("ForEach([64, 96, 128, 192, 256, 384]", ui)
        self.assertIn("Restart iDeck before the new Wine JIT pool size", ui)
        self.assertIn("updateWineJITPoolPreference(selected)", ui)
        self.assertNotIn("ideck_wine_jit_pool_prepare()", ui)

    def test_mono_is_only_shown_when_bundle_contains_real_module(self):
        settings = (ROOT / "iDeck/SettingsView.swift").read_text()
        env = (ROOT / "iDeck/WindowsEnvironment.swift").read_text()
        self.assertIn('runtime["wineMonoBundled"] as? Bool', settings)
        self.assertIn('Wine Mono is not included. Run iOS Build', settings)
        self.assertNotIn("downloadWineMono()", settings)
        self.assertIn('"wineMonoBundled"', env)
        self.assertIn("ideck_process_has_jit_permission()", settings)
        self.assertIn("coordinator.requestStikDebugJIT()", settings)

    def test_localization_and_no_jit_faking(self):
        locale = (ROOT / "iDeck/Localization.swift").read_text()
        self.assertIn('"Wine JIT pool size is selected before allocation and cannot change', locale)
        self.assertIn('"Wine Mono is not included.', locale)
        self.assertIn('"pt":', locale)
        self.assertIn('"es":', locale)
        bridge = (ROOT / "iDeck/SystemCoordinator.swift").read_text()
        self.assertIn('universal", withExtension: "js"', bridge)
        self.assertIn("isStikDebugAttached", bridge)


if __name__ == "__main__":
    unittest.main()
