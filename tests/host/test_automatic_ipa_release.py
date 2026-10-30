import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/ios.yml").read_text(encoding="utf-8")


class AutomaticIPAReleaseTests(unittest.TestCase):
    def test_release_runs_after_main_build_and_tests(self):
        release = WORKFLOW.split("\n  release:\n", 1)[1]
        self.assertIn("Verify PR iDeck IPA preview", release)
        self.assertIn("Publish verified iDeck IPA release", release)
        self.assertIn("needs: [checks, build]", release)
        self.assertIn("needs.checks.result == 'success'", release)
        self.assertIn("needs.build.result == 'success'", release)
        self.assertIn("github.ref == 'refs/heads/main'", release)
        self.assertIn("startsWith(github.ref, 'refs/tags/')", release)
        self.assertIn("github.event_name == 'workflow_dispatch'", release)
        self.assertNotIn("github.event_name != 'workflow_dispatch' || inputs.require_madeira", release)
        self.assertIn("github.event_name == 'pull_request' || github.event_name == 'workflow_dispatch'", release)

    def test_pr_final_job_runs_but_cannot_publish_a_github_release(self):
        release = WORKFLOW.split("\n  release:\n", 1)[1]
        self.assertIn("github.event_name == 'workflow_dispatch'", release)
        self.assertIn("github.event_name == 'push'", release)
        self.assertIn("github.event_name == 'pull_request'", release)
        self.assertIn("permissions:\n      contents: write", release)
        self.assertIn("if: ${{ github.event_name == 'pull_request' }}", release)
        self.assertIn("if: ${{ github.event_name != 'pull_request' }}", release)
        self.assertIn("name: Provide verified IPA to pull request", release)
        self.assertIn("A pull request does not create a public GitHub Release.", release)
        self.assertIn("needs.build.outputs.ipa_artifact_url", release)
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

    def test_auto_release_is_prerelease_and_not_latest(self):
        release = WORKFLOW.split("\n  release:\n", 1)[1]
        self.assertIn("needs.build.outputs.ipa_kind", release)
        self.assertIn("actions/download-artifact@v8", release)
        self.assertIn("GH_REPO: ${{ github.repository }}", release)
        self.assertIn("format('ideck-ci-{0}-{1}', github.run_id, github.run_attempt)", release)
        self.assertIn("OPTIONS+=(--prerelease --latest=false)", release)
        self.assertIn("No Windows Games", release)
        self.assertIn("does NOT include Wine, FEX, DXMT or D3D12", release)
        self.assertIn("if [[ \"$AUTO_TAG\" != \"true\" && \"$KIND\" != \"native\" ]]", release)
        self.assertIn('gh release create "$TAG" iDeck.ipa', release)
        self.assertIn('gh release upload "$TAG" iDeck.ipa --clobber', release)

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
