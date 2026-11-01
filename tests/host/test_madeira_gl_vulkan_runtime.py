import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


class MadeiraOpenGLVulkanRuntimeTests(unittest.TestCase):
    def test_madeira_pin_carries_gl_and_vulkan_sources(self):
        rev = "c2c1b03a9e36ef986c980b9eae3c14d05a372db1"
        for path in ("scripts/fetch_madeira_sources.sh", "scripts/verify_madeira_sources.py",
                     "scripts/madeira_native_kit.py"):
            self.assertIn(rev, read(path), path)
            self.assertNotIn("fd9f2f3d0434a4116e4c3351f286a0fc376b4e36", read(path), path)

    def test_opengl_presenter_and_frameworks_are_linked(self):
        link = read("scripts/link_madeira_native.sh")
        self.assertIn('"Winios/WiniosGL.m"', link)
        self.assertIn("-framework OpenGLES -framework IOSurface", link)
        self.assertIn('"$ROOT/build/host/"*.c', link)
        kit = read("scripts/madeira_native_kit.py")
        self.assertIn('"OpenGLES", "IOSurface"', kit)

    def test_swift_only_upstream_symbol_has_a_c_host(self):
        shim = read("build/host/madeira_host_input.c")
        self.assertIn("int winios_mouse_routing_enabled(void)", shim)
        self.assertIn('"env.MADEIRA_MOUSE_ROUTING"', shim)
        self.assertIn("int on = 1;", shim)
        bundle = read("scripts/verify_madeira_bundle.py")
        for symbol in ("madeira_gl_present", "madeira_display_layer_for_hwnd",
                       "winios_mouse_routing_enabled"):
            self.assertIn(f'"{symbol}"', bundle)

    def test_moltenvk_and_zink_are_built_pinned_and_cached(self):
        script = read("scripts/build_madeira_gl_vulkan.sh")
        self.assertIn('MOLTENVK_TAG="v1.4.2"', script)
        self.assertIn('MESA_VERSION="25.0.7"', script)
        self.assertIn("592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6", script)
        self.assertIn('bash "$MD/build/moltenvk-ios/build.sh"', script)
        self.assertIn('bash "$MD/build/mesa-ios/build.sh"', script)
        subprocess.run(["bash", "-n", str(ROOT / "scripts/build_madeira_gl_vulkan.sh")], check=True)
        components = read("scripts/build_madeira_components.sh")
        self.assertIn('bash "$ROOT/scripts/build_madeira_gl_vulkan.sh" "$MD"', components)
        self.assertIn('"$MD/app/Madeira/gl/libOSMesa.dylib"', components)
        workflow = read(".github/workflows/ios.yml")
        self.assertIn("path: build/gl-runtime-cache", workflow)
        self.assertIn("test_madeira_gl_vulkan_runtime.py", workflow)

    def test_vulkan_dlls_stay_outside_the_prefix_farm(self):
        stage = read("scripts/stage_madeira_payload.sh")
        self.assertIn('"$APP/vulkan/arm64ec-windows"', stage)
        self.assertIn('cp "$SOURCE/gl/libMoltenVK.dylib" "$SOURCE/gl/libOSMesa.dylib" "$APP/gl/"', stage)
        self.assertIn("d3d12*.dll) [[ \"$GRAPHICS\" == \"d3d12\" ]] || continue", stage)

    def test_game_profile_turns_vulkan_and_opengl_on_per_launch(self):
        model = read("iDeck/WindowsLibraryModels.swift")
        self.assertIn('static let vulkanModes = ["Automatic", "On", "Off"]', model)
        self.assertIn('static let openGLBackends = ["Automatic", "Desktop OpenGL", "OpenGL ES"]', model)
        self.assertIn("forKey: .vulkanMode", model)
        environment = read("iDeck/WindowsEnvironment.swift")
        self.assertIn("writeSessionGraphicsConfig(binary: binary, is32Bit: needsWoW64,", environment)
        self.assertIn('lines.append("vulkan = moltenvk")', environment)
        self.assertIn('lines.append("gl-backend = zink")', environment)
        self.assertIn('setenv("MADEIRA_CFG_GAME", file.path, 1)', environment)
        self.assertIn("graphicsAPIs(of: url) & UInt32(IDECK_API_VULKAN) != 0", environment)
        self.assertIn('{"vulkan-1.dll", IDECK_API_VULKAN}', read("iDeck/GraphicsAPIScan.c"))
        # 32-bit sessions never get Vulkan: upstream binds no WoW64 Vulkan table.
        self.assertIn('case "On" where runtime && !is32Bit:', environment)
        view = read("iDeck/MainView.swift")
        self.assertIn("selection: $profile.vulkanMode", view)
        self.assertIn("selection: $profile.openGLBackend", view)


if __name__ == "__main__":
    unittest.main()
