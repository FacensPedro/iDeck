import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/ios.yml").read_text()
BUILDER = (ROOT / "scripts/build_ipa.sh").read_text()
KITS = (ROOT / "scripts/madeira_native_kit.py").read_text()


class ActionsNativeDispatchMatrix(unittest.TestCase):
    def test_manual_default_is_real_d3d11_with_wow64(self):
        header = WORKFLOW.split("  push:", 1)[0]

        def field_default(name):
            # Match YAML input keys at exactly six spaces, not a prefix of
            # their eight-space nested description/type/default mappings.
            key = re.search(rf"(?m)^      {re.escape(name)}:\\s*$", header)
            self.assertIsNotNone(key, f"Missing workflow input: {name}")
            remaining = header[key.end():]
            sibling = re.search(r"(?m)^      [A-Za-z_][A-Za-z0-9_]*:\\s*$", remaining)
            block = remaining[:sibling.start()] if sibling else remaining
            default = re.search(r"(?m)^        default:\\s*(\\S+)\\s*$", block)
            self.assertIsNotNone(default, f"Missing default for workflow input: {name}")
            return default.group(1)

        self.assertEqual("true", field_default("require_madeira"))
        self.assertEqual("d3d11", field_default("graphics_profile"))
        self.assertEqual("true", field_default("build_wow64"))
        self.assertEqual("false", field_default("accept_converter_license"))
        self.assertEqual("false", field_default("bundle_wine_mono"))
        self.assertEqual("false", field_default("export_runtime_kit"))

    def test_native_build_not_enabled_on_pull_requests(self):
        native = re.search(r"^\s+IDECK_NATIVE_BUILD: (.+)$", WORKFLOW, re.MULTILINE)
        self.assertIsNotNone(native)
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.require_madeira", native.group(1))
        self.assertIn("github.event_name == 'push' && vars.IDECK_NATIVE_DISTRIBUTION_APPROVED == 'true'", native.group(1))
        self.assertNotIn("github.event_name == 'pull_request'", native.group(1))
        self.assertIn("this PR build does not contain FEX, Wine, DXMT or D3D12", WORKFLOW)

    def test_wow64_and_mono_require_native_consent(self):
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.require_madeira && inputs.build_wow64", WORKFLOW)
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.require_madeira && inputs.bundle_wine_mono", WORKFLOW)
        self.assertIn("env.IDECK_BUILD_WOW64 == '1'", WORKFLOW)
        self.assertIn("if os.environ[\"IDECK_BUILD_WOW64\"] == \"1\":", WORKFLOW)
        self.assertIn('export IDECK_BUILD_WOW64="${IDECK_BUILD_WOW64:-1}"', BUILDER)

    def test_unlicensed_d3d12_still_exits_two(self):
        start = WORKFLOW.index("- name: Validate native runtime requirements")
        end = WORKFLOW.index("- name: Restore incremental Xcode build intermediates", start)
        block = WORKFLOW[start:end]
        self.assertIn('"$IDECK_MADEIRA_GRAPHICS" == "d3d12"', block)
        self.assertIn('"$CONVERTER_LICENSE_ACK" != "1"', block)
        self.assertIn("exit 2", block)
        self.assertIn("explicit converter distribution permission", BUILDER)

    def test_public_d3d11_cache_is_enabled_and_strictly_partitioned(self):
        start = WORKFLOW.index("- name: Restore previously compiled Madeira runtime")
        end = WORKFLOW.index("- name: Install and validate Metal Toolchain", start)
        block = WORKFLOW[start:end]
        self.assertIn("if: ${{ env.IDECK_NATIVE_BUILD == '1' }}", block)
        for key in ("env.IDECK_MADEIRA_GRAPHICS", "env.IDECK_BUILD_WOW64",
                    "env.IDECK_BUNDLE_WINE_MONO", "scripts/madeira_native_kit.py",
                    "'patches/*'"):
            self.assertIn(key, block)
        self.assertIn('OPTIONS=(--graphics "$IDECK_MADEIRA_GRAPHICS")', block)
        self.assertIn("python3 scripts/madeira_native_kit.py inspect", block)
        self.assertIn("IDECK_PREBUILT_MODE: prefer", WORKFLOW)
        self.assertIn("IDECK_PREBUILT_EXPORT: ${{ env.IDECK_NATIVE_BUILD == '1'", WORKFLOW)
        self.assertIn('KIT_MODE="${IDECK_PREBUILT_MODE:-prefer}"', BUILDER)
        self.assertIn("D3D11 native kit includes forbidden D3D12 content", KITS)
        self.assertIn("graphics == \"d3d12\" and os.environ.get", KITS)

    def test_summary_is_truthful(self):
        self.assertIn("JIT and device signing are not verified", WORKFLOW)
        self.assertIn("kit cache:", WORKFLOW)
        self.assertIn("verified kit:", WORKFLOW)
        self.assertIn("Runtime kit SHA-256 mismatch", KITS)


if __name__ == "__main__":
    unittest.main()
