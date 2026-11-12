"""The ARM64EC context-return BRK logs why it was refused."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def patched_source() -> str:
    patch = (ROOT / "patches/madeira-arm64ec-mach-context-return.patch").read_text()
    return "\n".join(line[1:] for line in patch.splitlines() if line.startswith("+") and not line.startswith("+++")) + "\n"


def run(source: str):
    spec = importlib.util.spec_from_file_location("diag", ROOT / "scripts/apply_madeira_slowpath_diag.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / "build/ntdll-unix/signal_arm64_ios.c"
        path.parent.mkdir(parents=True)
        path.write_text(source)
        first = module.main(folder)
        second = module.main(folder) if first == 0 else None
        return first, second, path.read_text()


class SlowpathRefusalTests(unittest.TestCase):
    def test_every_check_after_the_brk_identity_reports_its_reason(self):
        first, second, text = run(patched_source())
        self.assertEqual((first, second), (0, 0))
        body = text[text.index("static int ios_mach_resume_arm64ec_slowpath("):]
        body = body[:body.index("\n}\n")]
        identity = body.index("insn != IDECK_ARM64EC_RETURN_BRK)")
        # Before the BRK is identified nothing is logged: other breakpoints stay silent.
        self.assertNotIn("ideck_slowpath_refused", body[:identity])
        self.assertEqual(body[identity:].count("return ideck_slowpath_refused("), 5)
        for reason in ("thread:", "teb self:", "frame pointer:", "frame unreadable:", "frame: a=restore_flags"):
            self.assertIn(reason, body)

    def test_accepted_contexts_are_unchanged(self):
        _, _, text = run(patched_source())
        for kept in ("frame.pc < 0x100000000ull || (frame.pc & 3) ||", "(frame.x[18] && frame.x[18] != teb))",
                     "thread_set_state( thread, ARM_THREAD_STATE64,", "return 1;"):
            self.assertIn(kept, text)

    def test_other_code_with_the_same_lines_is_left_alone(self):
        other = "static int other(void)\n{\n        got != sizeof(frame))\n        return 0;\n}\n"
        _, _, text = run(other + patched_source())
        self.assertIn(other, text)

    def test_an_unknown_source_stops_the_build_and_the_fetch_runs_it(self):
        self.assertEqual(run("int main(void) { return 0; }\n")[0], 2)
        fetch = (ROOT / "scripts/fetch_madeira_sources.sh").read_text()
        self.assertLess(fetch.index('apply_madeira_patches.py" "$DEST" native'),
                        fetch.index('python3 "$ROOT/scripts/apply_madeira_slowpath_diag.py" "$DEST"'))


if __name__ == "__main__":
    unittest.main()
