import os
import pathlib
import subprocess
import sys
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/ios.yml").read_text(encoding="utf-8")


class AutomaticIPAReleaseTests(unittest.TestCase):
    def test_release_verification_only_runs_for_pr_manual_or_approved_native_main(self):
        release = WORKFLOW.split("\n  release:\n", 1)[1]
        self.assertIn("needs: [checks, build]", release)
        self.assertIn("needs.checks.result == 'success'", release)
        self.assertIn("needs.build.result == 'success'", release)
        self.assertIn("github.event_name == 'pull_request' || github.event_name == 'workflow_dispatch'", release)
        self.assertIn("github.ref == 'refs/heads/main' && needs.build.outputs.ipa_kind == 'native'", release)
        self.assertNotIn("startsWith(github.ref, 'refs/tags/')", release)

    def test_pr_final_job_runs_but_cannot_publish_a_github_release(self):
        release = WORKFLOW.split("\n  release:\n", 1)[1]
        self.assertIn("github.event_name == 'workflow_dispatch'", release)
        self.assertIn("github.event_name == 'push' && github.ref == 'refs/heads/main'", release)
        self.assertIn("github.event_name == 'pull_request'", release)
        self.assertIn("permissions:\n      contents: write", release)
        self.assertIn("if: ${{ github.event_name == 'pull_request' }}", release)
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.release_tag != ''", release)
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
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.release_tag != ''", release)
        self.assertIn("TAG: ${{ github.event_name == 'push' && 'auto' || inputs.release_tag }}", release)
        self.assertIn('[[ -n "${TAG//[[:space:]]/}" ]]', release)
        self.assertNotIn("AUTO_TAG:", release)
        self.assertNotIn("format('ideck-ci-{0}-{1}', github.run_id, github.run_attempt)", release)
        self.assertIn('if [[ "$KIND" != "native" ]]; then', release)
        self.assertIn('gh release upload "$TAG" iDeck.ipa iDeck.ipa.sha256 iDeck-distribution-audit.json --clobber', release)
        self.assertIn('gh release create "$TAG" iDeck.ipa iDeck.ipa.sha256 iDeck-distribution-audit.json', release)
        self.assertIn("sha256sum --check iDeck.ipa.sha256", release)

    def test_release_checks_out_notes_and_updates_existing_version(self):
        release = WORKFLOW.split("\n  release:\n", 1)[1]
        self.assertIn("name: Checkout release notes", release)
        self.assertIn("uses: actions/checkout@v5", release)
        self.assertIn("persist-credentials: false", release)
        self.assertIn("test -s RELEASE_NOTES.md", release)
        self.assertIn('gh release edit "$TAG" --title "$TITLE" --notes-file RELEASE_NOTES.md', release)
        self.assertIn('gh release create "$TAG" iDeck.ipa iDeck.ipa.sha256 iDeck-distribution-audit.json', release)
        notes = (ROOT / "RELEASE_NOTES.md").read_text(encoding="utf-8")
        self.assertNotIn("# iDeck 1.0.0", notes)
        self.assertTrue(notes.startswith("## What's Changed\n"))

    def test_one_time_1_0_5_release_request_requires_native_main_and_does_not_clobber(self):
        release = WORKFLOW.split("\n  release:\n", 1)[1]
        requested = (ROOT / ".github/release-request.txt").read_text(encoding="utf-8").strip()
        self.assertEqual(requested, "1.0.5")
        self.assertIn("needs.build.outputs.ipa_kind == 'native'", release)
        self.assertIn("github.ref == 'refs/heads/main'", release)
        self.assertIn('test -s .github/release-request.txt', release)
        self.assertIn('REQUESTED="$(tr -d \'[:space:]\' < .github/release-request.txt)"', release)
        self.assertIn('if [[ "$REQUESTED" != "$VERSION" ]]; then', release)
        self.assertIn('if [[ "$GITHUB_EVENT_NAME" == "push" ]]; then', release)
        self.assertIn('Release $TAG already exists. Refusing to overwrite', release)
        self.assertIn('sha256sum --check iDeck.ipa.sha256', release)
        self.assertIn('if [[ "$KIND" != "native" ]]; then', release)

    def test_manual_tag_mismatch_fails_before_an_expensive_native_build(self):
        checks = WORKFLOW.split("\n  checks:\n", 1)[1].split("\n  build:\n", 1)[0]
        name = "Reject mismatched manual release tags before building"
        self.assertIn(name, checks)
        self.assertLess(checks.index(name), checks.index("Setup Xcode"))
        guard = checks.split("      - name: " + name, 1)[1].split("      - name: Setup Xcode", 1)[0]
        self.assertIn("github.event_name == 'workflow_dispatch'", guard)
        self.assertIn("REQUESTED_RELEASE_TAG:", guard)
        script = textwrap.dedent(guard.split("python3 - <<'PY'\n", 1)[1].split("\n          PY", 1)[0])

        for tag, expected_ok in (("1.0.5", True), ("v1.0.5", True), ("1.0.4", False), ("v1.0.6", False)):
            with self.subTest(tag=tag):
                env = os.environ.copy()
                env["REQUESTED_RELEASE_TAG"] = tag
                result = subprocess.run([sys.executable, "-c", script], cwd=ROOT, env=env,
                                        text=True, capture_output=True, check=False)
                self.assertEqual(result.returncode == 0, expected_ok,
                                 result.stdout + result.stderr)
                if not expected_ok:
                    self.assertIn("does not match project version v1.0.5", result.stderr)

    def test_auto_release_tag_uses_the_verified_ipa_version(self):
        release = WORKFLOW.split("\n  release:\n", 1)[1]
        self.assertIn('elif [[ "$TAG" == "auto" ]]; then', release)
        self.assertIn('TAG="v$VERSION"', release)
        self.assertIn('CFBundleShortVersionString', release)
        self.assertIn('Payload/iDeck.app/Info.plist', release)
        self.assertIn('TAG#v', release)
        self.assertIn('if [[ "$KIND" != "native" ]]; then', release)

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
