import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/ios.yml").read_text(encoding="utf-8")


class AutomaticIPAReleaseTests(unittest.TestCase):
    def test_release_verification_only_runs_for_pr_or_manual_build(self):
        release = WORKFLOW.split("\n  release:\n", 1)[1]
        self.assertIn("needs: [checks, build]", release)
        self.assertIn("needs.checks.result == 'success'", release)
        self.assertIn("needs.build.result == 'success'", release)
        self.assertIn("github.event_name == 'pull_request' || github.event_name == 'workflow_dispatch'", release)
        self.assertNotIn("github.ref == 'refs/heads/main'", release)
        self.assertNotIn("startsWith(github.ref, 'refs/tags/')", release)

    def test_pr_final_job_runs_but_cannot_publish_a_github_release(self):
        release = WORKFLOW.split("\n  release:\n", 1)[1]
        self.assertIn("github.event_name == 'workflow_dispatch'", release)
        self.assertNotIn("github.event_name == 'push'", release)
        self.assertIn("github.event_name == 'pull_request'", release)
        self.assertIn("permissions:\n      contents: write", release)
        self.assertIn("if: ${{ github.event_name == 'pull_request' }}", release)
        self.assertIn("if: ${{ github.event_name == 'workflow_dispatch' && inputs.release_tag != '' }}", release)
        self.assertIn("name: Provide verified IPA to pull request", release)
        self.assertIn("A pull request does not create a public GitHub Release.", release)
        self.assertIn("needs.build.outputs.ipa_artifact_url", release)
        self.assertIn(
            "github.event_name == 'workflow_dispatch' && inputs.release_tag != ''",
            release,
        )
        self.assertNotIn("format('ideck-ci-", release)
        self.assertIn('test -s iDeck.ipa', release)
        self.assertIn('unzip -tq iDeck.ipa', release)

    def test_pr_artifact_url_is_output_from_successful_build_only(self):
        build = WORKFLOW.split("\n  build:\n", 1)[1].split("\n  release:\n", 1)[0]
        release = WORKFLOW.split("\n  release:\n", 1)[1]
        self.assertIn("ipa_artifact_url: ${{ steps.ipa_artifact.outputs.artifact-url }}", build)
        self.assertIn("id: ipa_artifact", build)
        self.assertIn("archive: false", build)
        self.assertIn('[[ "$IPA_URL" == https://github.com/*/actions/runs/*/artifacts/* ]]', release)
        self.assertIn('[[ "$IPA_KIND" == "interface" || "$IPA_KIND" == "native" ]]', release)
        self.assertIn('A pull request does not create a public GitHub Release.', release)

    def test_exact_ipa_build_kind_is_exposed_by_packaged_file(self):
        build = WORKFLOW.split("\n  build:\n", 1)[1].split("\n  release:\n", 1)[0]
        self.assertIn("ipa_kind: ${{ steps.detect_ipa_kind.outputs.kind }}", build)
        self.assertIn("id: detect_ipa_kind", build)
        self.assertIn('manifest_path = "Payload/iDeck.app/MadeiraRuntimeManifest.plist"', build)
        self.assertIn('kind = "interface"', build)
        self.assertIn('kind = "native"', build)
        self.assertIn("Incomplete Madeira native manifest; release refused", build)
        self.assertIn("Native runtime requested but the packaged IPA is interface-only", build)
        self.assertIn('output.write(f"kind={kind}\\n")', build)
        self.assertIn("archive: false", build)

    def test_release_requires_explicit_manual_version_input(self):
        release = WORKFLOW.split("\n  release:\n", 1)[1]
        self.assertIn("needs.build.outputs.ipa_kind", release)
        self.assertIn("actions/download-artifact@v8", release)
        self.assertIn("GH_REPO: ${{ github.repository }}", release)
        self.assertIn("if: ${{ github.event_name == 'workflow_dispatch' && inputs.release_tag != '' }}", release)
        self.assertIn("TAG: ${{ inputs.release_tag }}", release)
        self.assertIn('[[ -n "${TAG//[[:space:]]/}" ]]', release)
        self.assertNotIn("AUTO_TAG:", release)
        self.assertNotIn("format('ideck-ci-{0}-{1}', github.run_id, github.run_attempt)", release)
        self.assertIn('if [[ "$KIND" != "native" ]]; then', release)
        self.assertIn('gh release upload "$TAG" iDeck.ipa iDeck.ipa.sha256 iDeck-distribution-audit.json --clobber', release)
        self.assertIn('gh release create "$TAG" iDeck.ipa iDeck.ipa.sha256 iDeck-distribution-audit.json', release)
        self.assertIn("sha256sum --check iDeck.ipa.sha256", release)

    def test_versioned_release_rejects_ui_only_and_tampered_native_manifest(self):
        release = WORKFLOW.split("\n  release:\n", 1)[1]
        self.assertIn("Versioned releases require verified Wine/FEX/DXMT/D3D12", release)
        self.assertIn("has_manifest != (kind == \"native\")", release)
        for field in ("fexInProcess", "wineInProcess", "dxmtLinked", "d3d12Linked"):
            self.assertIn(field, release)
        self.assertIn("test -s iDeck.ipa", release)
        self.assertIn("unzip -tq iDeck.ipa", release)


if __name__ == "__main__":
    unittest.main()
