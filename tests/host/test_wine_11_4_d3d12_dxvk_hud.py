import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
GRAPHICS = (ROOT / "iDeck/GraphicsConfig.swift").read_text(encoding="utf-8")
SETTINGS = (ROOT / "iDeck/SettingsView.swift").read_text(encoding="utf-8")
FETCH = (ROOT / "scripts/fetch_madeira_sources.sh").read_text(encoding="utf-8")
COMPONENTS = (ROOT / "scripts/build_madeira_components.sh").read_text(encoding="utf-8")
STAGING = (ROOT / "scripts/stage_madeira_payload.sh").read_text(encoding="utf-8")
KIT = (ROOT / "scripts/madeira_native_kit.py").read_text(encoding="utf-8")
VERIFIER = (ROOT / "scripts/verify_madeira_bundle.py").read_text(encoding="utf-8")
ENVIRONMENT = (ROOT / "iDeck/WindowsEnvironment.swift").read_text(encoding="utf-8")


class Wine114NativeD3D12AndAutomaticDXVKHUDTests(unittest.TestCase):
    def test_dxvk_hud_is_automatic_without_forcing_the_metal_hud(self):
        self.assertIn('setenv("DXVK_HUD", "devinfo,fps", 0)', GRAPHICS)
        self.assertIn('setenv("MTL_HUD_ENABLED", "1", 1)', GRAPHICS)
        self.assertIn('unsetenv("MTL_HUD_ENABLED")', GRAPHICS)
        self.assertNotIn('unsetenv("DXVK_HUD")', GRAPHICS)
        self.assertNotIn('toggleRow(title: tr("DXVK HUD")', SETTINGS)
        self.assertIn('toggleRow(title: tr("Metal diagnostics HUD")', SETTINGS)
        self.assertIn('graphicsConfig.applyGraphicsEnvironment()', ENVIRONMENT)

    def test_wine_11_4_is_pinned_to_the_ios_arm64ec_fork(self):
        self.assertIn('https://github.com/willfaust/Madeira.git', FETCH)
        self.assertIn('"Wine version 11.4"', FETCH)
        self.assertIn('"Wine version 11.4"', COMPONENTS)
        self.assertIn('WINE_VERSION = "11.4"', KIT)
        self.assertIn('"wine_version": WINE_VERSION', KIT)
        self.assertIn('metadata.get("wine_version") != WINE_VERSION', KIT)
        self.assertNotIn('git clone https://github.com/wine-mirror/wine', FETCH)

    def test_native_d3d12_loader_is_not_silently_replaced(self):
        self.assertIn('bash "$MD/build/madeira-d3d12/build-pe.sh"', COMPONENTS)
        self.assertIn('cmp -s "$D3D/madeira_d3d12.dll" "$D3D/d3d12.dll"', COMPONENTS)
        self.assertIn('cmp -s "$APP/arm64ec-windows/madeira_d3d12.dll"', STAGING)
        self.assertIn('D3D12_FRONTEND = "arm64ec-windows/madeira_d3d12.dll"', KIT)
        self.assertIn('D3D12_CORE = "arm64ec-windows/d3d12core.dll"', KIT)
        self.assertIn('"d3d12_backend": "madeira-d3d12"', KIT)
        self.assertIn('digest_file(app / D3D12_FRONTEND) != digest_file(app / D3D12_LOADER)', KIT)
        self.assertIn('D3D12 loader differs from Madeira native frontend', VERIFIER)
        self.assertIn('"arm64ec-windows/madeira_d3d12.dll"', ENVIRONMENT)

if __name__ == "__main__":
    unittest.main()
