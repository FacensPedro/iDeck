from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/ios.yml").read_text(encoding="utf-8")
PACKAGER = (ROOT / "scripts/build_ipa.sh").read_text(encoding="utf-8")
STAGER = (ROOT / "scripts/stage_madeira_payload.sh").read_text(encoding="utf-8")
VERIFIER = (ROOT / "scripts/verify_madeira_bundle.py").read_text(encoding="utf-8")


class AutomaticNativeIPATests(unittest.TestCase):
    def test_automatic_push_pr_and_tag_builds_require_full_madeira_runtime(self):
        self.assertIn(
            "IDECK_NATIVE_BUILD: ${{ github.event_name != 'workflow_dispatch' && '1' || "
            "(inputs.require_madeira && '1' || '0') }}",
            WORKFLOW,
        )
        self.assertIn('branches: [ "main", "ci/automatic-full-madeira-runtime-ipa-20261029" ]', WORKFLOW)
        self.assertIn('pull_request:', WORKFLOW)
        self.assertIn('tags: [ "v*", "[0-9]*" ]', WORKFLOW)
        self.assertIn('Verify automatic builds cannot downgrade to interface-only', WORKFLOW)

    def test_distribution_approval_is_explicit_and_never_inferred_from_build(self):
        self.assertIn("vars.IDECK_NATIVE_DISTRIBUTION_APPROVED == 'true'", WORKFLOW)
        self.assertIn('Validate native runtime requirements', WORKFLOW)
        self.assertIn('if [[ "$CONVERTER_LICENSE_ACK" != "1" ]]', WORKFLOW)
        self.assertIn('No interface-only IPA will be uploaded.', WORKFLOW)
        self.assertNotIn("IDECK_ACCEPT_METAL_CONVERTER_LICENSE: '1'", WORKFLOW)
        self.assertIn('IDECK_ACCEPT_METAL_CONVERTER_LICENSE: ${{ env.IDECK_ACCEPT_METAL_CONVERTER_LICENSE }}', WORKFLOW)

    def test_full_build_fetches_or_restores_native_and_does_not_substitute_stubs(self):
        for step in (
            'Restore previously compiled Madeira runtime',
            'Locate repository or cached Madeira runtime',
            'Install and validate Metal Toolchain',
            'Install Madeira native build dependencies',
            'Fetch pinned Madeira with FEX, Wine and DXMT',
            'Prepare ARM64EC and iOS LLVM toolchains',
            'Build and package iDeck.ipa',
        ):
            self.assertIn(step, WORKFLOW)
        self.assertIn('bash scripts/build_madeira_components.sh', PACKAGER)
        self.assertIn('bash scripts/link_madeira_native.sh', PACKAGER)
        self.assertIn('python3 scripts/madeira_native_kit.py install', PACKAGER)
        self.assertIn('IDECK_REQUIRE_MADEIRA: ${{ env.IDECK_NATIVE_BUILD }}', WORKFLOW)

    def test_zip_contains_native_madeira_fex_wine_dxmt_d3d12_and_xinput(self):
        for item in (
            'MadeiraRuntimeManifest.plist',
            'arm64ec-windows/xtajit64.dll',
            'arm64ec-windows/madeira_d3d12.dll',
            'arm64ec-windows/d3d12.dll',
            'arm64ec-windows/d3d12core.dll',
            'arm64ec-windows/d3d11.dll',
            'arm64ec-windows/dxgi.dll',
            'arm64ec-windows/xinput1_4.dll',
            'd3d12/libmetalirconverter.dylib',
            'prefix-template.tar.gz',
        ):
            self.assertIn(item, WORKFLOW)
        self.assertIn('"fexInProcess", "wineInProcess", "dxmtLinked", "d3d12Linked"', WORKFLOW)
        self.assertIn('data[:2] != b"MZ"', WORKFLOW)
        self.assertIn('D3D12 loader differs from the Madeira D3D12 frontend', WORKFLOW)
        self.assertIn('python3 scripts/verify_madeira_bundle.py --app "$APP" --require', PACKAGER)
        self.assertIn('MadeiraRuntime', STAGER)

    def test_ipa_remains_a_direct_raw_ipa_artifact(self):
        self.assertIn('name: Upload IPA directly (no outer ZIP)', WORKFLOW)
        self.assertIn('uses: actions/upload-artifact@v7', WORKFLOW)
        self.assertIn('archive: false', WORKFLOW)
        self.assertIn('path: iDeck.ipa', WORKFLOW)
        self.assertNotIn('unzip -o iDeck.ipa', WORKFLOW)


if __name__ == "__main__":
    unittest.main()
