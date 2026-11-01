import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("check_language_layers", ROOT / "scripts/check_language_layers.py")
layers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layers)


class LanguageLayerTests(unittest.TestCase):
    def test_repository_follows_language_layers(self):
        self.assertEqual(layers.check(ROOT), [])

    def test_epic_chunk_codec_is_cpp_behind_objective_cpp(self):
        swift = (ROOT / "iDeck/EpicFormats.swift").read_text()
        self.assertIn("IDEpicChunkCodec.inflate(data, size:", swift)
        self.assertIn("IDEpicChunkCodec.sha1(data)", swift)
        self.assertNotIn("compression_decode_buffer", swift)
        self.assertIn('#include "EpicChunkCodec.hpp"', (ROOT / "iDeck/EpicChunkBridge.mm").read_text())
        self.assertIn('#import "EpicChunkBridge.h"', (ROOT / "iDeck/iDeck-Bridging-Header.h").read_text())
        self.assertFalse(layers.has_cxx((ROOT / "iDeck/EpicChunkBridge.h").read_text()))

    def test_detector_flags_cpp_in_a_swift_visible_header(self):
        self.assertTrue(layers.has_cxx("namespace ideck { int x; }"))
        self.assertTrue(layers.has_cxx("void f(std::vector<int>);"))
        self.assertFalse(layers.has_cxx('#ifdef __cplusplus\nextern "C" {\n#endif\nint f(void);\n#ifdef __cplusplus\n}\n#endif'))


class WineJITPoolMatchesMadeiraTests(unittest.TestCase):
    CPP = (ROOT / "iDeck/NativeRuntime/FEXRuntime.cpp").read_text()

    def test_pool_uses_madeira_session_size(self):
        self.assertIn("constexpr size_t allowed[] = {1152, 896, 768, 640, 512, 384, 256};", self.CPP)
        self.assertIn("if (physical_bytes >= 6ULL * 1024 * MiB) preferred = 896;", self.CPP)

    def test_executable_window_is_held_before_rx(self):
        self.assertIn('setenv("WINE_IOS_EXE_WINDOW", "140000000:8000000", 1)', self.CPP)
        frontier = self.CPP.index("void prepare_wine_pool_frontier() {")
        self.assertIn("reserve_exe_window();", self.CPP[frontier:frontier + 200])


if __name__ == "__main__":
    unittest.main()
