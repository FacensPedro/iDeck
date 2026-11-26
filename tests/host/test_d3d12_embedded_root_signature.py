"""A compute pipeline without a root signature uses the one in its shader (2.16.2)."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATCH = (ROOT / "patches" / "madeira-d3d12-embedded-root-signature.patch").read_text()


class EmbeddedRootSignature(unittest.TestCase):
    def test_series(self):
        self.assertIn("early     .      madeira-d3d12-embedded-root-signature.patch",
                      (ROOT / "patches" / "series.txt").read_text())
        self.assertIn("+++ b/madeira-d3d12/src/pe/madeira_d3d12.c", PATCH)

    def test_compute_pipeline_takes_rts0(self):
        self.assertIn("+static ID3D12RootSignature *mad_embedded_rootsig(", PATCH)
        self.assertIn("+    if (!desc->pRootSignature) {", PATCH)
        self.assertIn("rs_find_chunk(code, len, &n, &why)", PATCH)


if __name__ == "__main__":
    unittest.main()
