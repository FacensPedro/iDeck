import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "patches" / "dxmt-metal27-tessellation-atomic.patch"
SHADER_PATH = Path("src/airconv/shaders/air_tessellation.metal")
OLD = "__metal_atomic_fetch_add_explicit(out_count, 1, int(memory_order_relaxed), __METAL_MEMORY_SCOPE_THREADGROUP__)"
NEW = "atomic_fetch_add_explicit(\n      reinterpret_cast<threadgroup atomic_int *>(out_count), 1, memory_order_relaxed)"


@unittest.skipUnless(shutil.which("git"), "git executable required")
class DXMTShaderPatchTests(unittest.TestCase):
    def test_patch_updates_legacy_tessellation_atomic(self):
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary)
            target = checkout / SHADER_PATH
            target.parent.mkdir(parents=True)
            initial = (
                "struct TessMeshWorkload {\n  int patch_index;\n};\n\n"
                "int\nget_next_index(threadgroup int *out_count) {\n"
                "  return " + OLD + ";\n}\n\n"
                "template <partitioning partition>\n"
            )
            target.write_text(initial, encoding="utf-8")
            subprocess.run(["git", "init", "-q", str(checkout)], check=True)
            subprocess.run(["git", "-C", str(checkout), "apply", "--check", str(PATCH)], check=True)
            subprocess.run(["git", "-C", str(checkout), "apply", str(PATCH)], check=True)
            patched = target.read_text(encoding="utf-8")
            self.assertNotIn(OLD, patched)
            self.assertIn(NEW, patched)
            reapply = subprocess.run(
                ["git", "-C", str(checkout), "apply", "--check", str(PATCH)],
                capture_output=True, check=False,
            )
            self.assertNotEqual(reapply.returncode, 0)

    def test_patch_is_limited_to_expected_shader(self):
        data = PATCH.read_text(encoding="utf-8")
        self.assertEqual(data.count("diff --git "), 1)
        self.assertIn("a/" + SHADER_PATH.as_posix(), data)
        self.assertIn("b/" + SHADER_PATH.as_posix(), data)
        self.assertIn("-  return " + OLD + ";", data)


if __name__ == "__main__":
    unittest.main()
