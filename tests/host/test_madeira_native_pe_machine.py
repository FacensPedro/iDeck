import shutil
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / "iDeck/NativeRuntime/WindowsPEMachine.h"
NATIVE = ROOT / "iDeck/NativeRuntimeDiagnostics.mm"
BRIDGE = ROOT / "iDeck/NativeRuntime/MadeiraRuntimeBridge.mm"
SWIFT = ROOT / "iDeck/WindowsEnvironment.swift"


def make_pe(machine: int, magic: int, optional: int) -> bytes:
    data = bytearray(1024)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HH", data, 0x84, machine, 1)
    struct.pack_into("<H", data, 0x94, optional)
    struct.pack_into("<H", data, 0x98, magic)
    return bytes(data)


class NativePEMachineTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def build(self, compiler, language):
        if not shutil.which(compiler):
            self.skipTest(f"{compiler} not installed")
        suffix = ".cpp" if language == "c++" else ".c"
        main = self.root / f"machine{suffix}"
        main.write_text(
            '#include <stdio.h>\n'
            '#include "WindowsPEMachine.h"\n'
            'int main(int argc, char **argv) {\n'
            '    if (argc != 2) return 2;\n'
            '    printf("%u\\n", (unsigned)ideck_pe_machine_from_file(argv[1]));\n'
            '    return 0;\n'
            '}\n',
            encoding="utf-8",
        )
        binary = self.root / ("machine-" + language.replace("+", "p"))
        subprocess.run(
            [compiler, "-Wall", "-Wextra", "-Werror", "-std=c++17" if language == "c++" else "-std=gnu11",
             "-I", str(HEADER.parent), str(main), "-o", str(binary)],
            check=True, capture_output=True, text=True,
        )
        return binary

    def test_parses_and_rejects_guest_executables_in_c_and_cpp(self):
        cases = [
            (make_pe(0x014C, 0x010B, 224), 0x014C),
            (make_pe(0x8664, 0x020B, 240), 0x8664),
            (make_pe(0xA641, 0x020B, 240), 0xA641),
            (make_pe(0x014C, 0x020B, 224), 0),
            (make_pe(0x8664, 0x010B, 240), 0),
            (make_pe(0xAA64, 0x020B, 240), 0),
            (bytes(1024), 0),
            (b"MZ" + bytes(30), 0),
        ]
        corrupted_offset = bytearray(make_pe(0x014C, 0x010B, 224))
        struct.pack_into("<I", corrupted_offset, 0x3C, 0x4000000)
        cases.append((bytes(corrupted_offset), 0))
        for compiler, lang in (("cc", "c"), ("c++", "c++")):
            binary = self.build(compiler, lang)
            for i, (fixture, expected) in enumerate(cases):
                with self.subTest(language=lang, index=i):
                    path = self.root / f"case-{i}.exe"
                    path.write_bytes(fixture)
                    result = subprocess.run([str(binary), str(path)], capture_output=True,
                                            text=True, check=True)
                    self.assertEqual(int(result.stdout.strip()), expected)

    def test_native_and_swift_share_the_same_architecture_decision(self):
        self.assertIn("ideck_pe_machine_from_file(path)", NATIVE.read_text())
        self.assertIn("uint16_t guestMachine = ideck_native_pe_machine", BRIDGE.read_text())
        self.assertIn('if (guestMachine == 0x014c)', BRIDGE.read_text())
        self.assertIn("let actualMachine = binary.path.withCString", SWIFT.read_text())
        self.assertIn("let needsWoW64 = actualMachine == 0x014c", SWIFT.read_text())
        self.assertIn("name.hasPrefix(\"i386-windows/\")", SWIFT.read_text())

    def test_native_build_defaults_wow64_on_both_graphics_backends(self):
        for script in ("scripts/build_ipa.sh", "scripts/build_native_runtime.sh"):
            source = (ROOT / script).read_text()
            self.assertIn('IDECK_BUILD_WOW64="${IDECK_BUILD_WOW64:-1}"', source)
        self.assertIn('IDECK_BUILD_WOW64 must be 0 or 1',
                      (ROOT / "scripts/build_ipa.sh").read_text())

    def test_session_releases_input_and_waits_for_guest_readiness(self):
        wine = (ROOT / "iDeck/NativeRuntime/WineProcessBridge.mm").read_text()
        bridge = BRIDGE.read_text()
        self.assertIn("for (unsigned int attempt = 0; attempt < 50; ++attempt)", wine)
        self.assertIn("if (ideck_wineprocess_running()) return 0;", wine)
        self.assertIn("ideck_gamepad_end_session();\n    ideck_session_stop();", bridge)
        self.assertIn("ideck_wineprocess_thread_finished()", bridge)



if __name__ == "__main__":
    unittest.main()
