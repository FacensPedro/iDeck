"""Exercise the native bounded Wine log classifier with real compiled C code."""
import ctypes
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "iDeck/NativeRuntime/WineLogTriage.c"


class ExtendedWineLogDiagnosticsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        extension = ".dylib" if sys.platform == "darwin" else ".so"
        library = Path(cls.temp.name) / ("libtriage" + extension)
        command = ["cc", "-std=c11", "-D_DARWIN_C_SOURCE", "-D_GNU_SOURCE", "-O2"]
        command += ["-dynamiclib" if sys.platform == "darwin" else "-shared", "-fPIC",
                    str(SOURCE), "-o", str(library)]
        subprocess.run(command, check=True, capture_output=True, text=True)
        cls.native = ctypes.CDLL(str(library))
        cls.native.ideck_wine_log_diagnose.argtypes = [ctypes.c_char_p]
        cls.native.ideck_wine_log_diagnose.restype = ctypes.c_int32

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def classify(self, content):
        path = Path(self.temp.name) / "session.log"
        path.write_text(content, encoding="utf-8")
        return self.native.ideck_wine_log_diagnose(os.fsencode(path))

    def test_wineserver(self):
        self.assertEqual(self.classify("wineserver timeout during startup"), 9)

    def test_graphics(self):
        self.assertEqual(self.classify("DXMT] failed to present a frame"), 10)

    def test_cpu_instruction(self):
        self.assertEqual(self.classify("guest process aborted 0xC000001D"), 11)

    def test_transport(self):
        self.assertEqual(self.classify("FATAL Error: usbmux timeout"), 12)

    def test_download_integrity(self):
        self.assertEqual(self.classify("checksum mismatch for a game chunk"), 13)

    def test_legacy_categories_preserved(self):
        self.assertEqual(self.classify("err:module:import_dll dll not found"), 5)
        self.assertEqual(self.classify("unhandled page fault c0000005"), 4)

    def test_prior_session_does_not_pollute_current(self):
        content = ("[wineserver-bridge] ws_log test\n"
                   "DXMT] failed to present\n"
                   "[wineserver-bridge] ws_log test\n"
                   "Wine guest exited normally\n")
        self.assertEqual(self.classify(content), 0)

    def test_empty_log(self):
        self.assertEqual(self.classify(""), 0)


if __name__ == "__main__":
    unittest.main()
