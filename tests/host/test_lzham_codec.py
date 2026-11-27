"""LZHAM support for Ubisoft slices (compressionMethod 2).

The fixture is a 20000-byte buffer written by lzham_codec's own compressor
(d379b1f, dict_size_log2 15, LZHAM_COMP_FLAG_WRITE_ZLIB_STREAM), the layout
Ubisoft uses for its slices.
"""
from __future__ import annotations

import split_sources  # noqa: F401  (iDeck 3.0 split files)
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = ROOT / "iDeck"

FIXTURE = bytes.fromhex(
    "0e88400000aa400070e151c232a31383fb1464d545b626970777e858c939aa1a8af90b6bdc4cbd2d9e0e7eef5fc030a1"
    "1181f262d343b42495057017602011b03030301e603037d120a4ae25b5bcc3cad1d8dfe6edf4fbbe0b10171e252c333a"
    "41484f565d646b727980878e959ca3aab1b8bfc6cdd4dbe2e90af0f7fe9531052272aa5ae31b538bc3fc346ca4dd154d"
    "85bdf62e669ed70f477fb7e8205890c9013971a9e21a528ac2fb336ba3dc144c84bcf52889526d689005f659b6c737a8"
    "1888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930373e454c322af60b4b040c131a21282f363d444b52596"
    "0676e757c838a91989fa6adb4bbc2c9d0d7dee5ecf37f2a9f0bb0adb3bac1c8cfd6dde4ebf2f98cbd1900b02a400bc15"
    "25a61686f767d848b9299a0c7132a57e90bf4f8070f167f1d242b3239404713c22a90c52d009d042a1f3926d7042ac5d"
    "a260b042a0a82263c042a2d2508090a55a6125810aa35dc22482007884204d225f70c1d08006e01022e00a04a9081177"
    "81029f03104ae0801772102045d7840b140b2115c2211df20814dfc102026fc04080f3e6102cc04d840a80084102d07a"
    "020270c804086e66a91a0324800a86e840126820803785610074ee8200be8384011e0944038c100005c0200008c84010"
    "0b60e2c07b27fdfd0cd1f804a9881854794c200e1dc0fdc8f8635f7647c3156235de19279f8449d54847c314f145f862"
    "205e18c0cc8bc3141a417863ca2f0c80428bc3138158b863b02f0c612445e18960bc36310e2f0c5e45f1e18908a8710a"
    "c5420c5422e2a2a1b9150b0da0a84545435e0c2a15c15148a2c2a29a2150a7e50a87c854bebfa22c202941150f3d98a8"
    "6405426d622a1d8150c30a0084bc5421c54002f62a121f91607a1789ffcba00e532083d4cc80615814e111ac0a709605"
    "384b029c2515814e12c0a709605384b029c278238eb065e12c1c6a709605384b029c25814e12c0a70921605384b029c2"
    "5814e12c0a709605384b029c25814e12c0a70960165384b029c25814e12c0a709606746746746746881549fd97c72380"
    "23003a33a33a33a33a33a33a33a33a2a960078f2feba8d522100e33201540193088ec89088fd29088e8dd088e909ae8e"
    "9088ff49088e86c04d1fe8909208e9088ee09088e908894e9088e9086a8e9088fd4688004ef109088e909b88e9088e91"
    "b088e9088ea29088e9088ec29088e908896e9088e9085a8e9088e877088e9088e909089258a42239424223a42783dfd5"
    "25e111d211001d2111d2111e5ce9088e009088e928007f709fd007333791a6824076ab4fd4eb0070469faee0e362cfac"
    "3578e0ff52fc11cebf5d1151c0beaf9b23b13ea423bcc1fd71870b2a7d5c87517d79a38f48fd68c707faabf30e96faf0"
    "cd4113dbf35fe19a4221a7224ccfec23ee7088ea334073cba1a4cf291ef32c8d134a4141733c8f29944619a4a1d8c152"
    "40c3268bc31286b3ac4754c0458c7895cb98c00e811cb3228a734642c99b00470cd3ef2000c0eb484dfa"
)


def expected_plain() -> bytes:
    return bytes(((i * 7) & 0xFF) if i % 97 < 50 else ((i * 31 >> 3) & 3) for i in range(20000))


MAIN = r"""
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include "LzhamCodec.h"
int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "rb");
    static uint8_t src[1 << 16], dst[1 << 16];
    size_t n = fread(src, 1, sizeof src, f);
    fclose(f);
    size_t capacity = (size_t)atoi(argv[3]);
    int64_t written = ideck_lzham_decompress(src, n, dst, capacity, 15);
    printf("%lld\n", (long long)written);
    if (written > 0) { FILE *o = fopen(argv[2], "wb"); fwrite(dst, 1, (size_t)written, o); fclose(o); }
    return 0;
}
"""


class LzhamCodecTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler = shutil.which("c++") or shutil.which("clang++") or shutil.which("g++")
        cls.tmp = tempfile.TemporaryDirectory()
        cls.binary = None
        if cls.compiler:
            tmp = pathlib.Path(cls.tmp.name)
            (tmp / "main.cpp").write_text(MAIN)
            cls.binary = tmp / "lzham_check"
            subprocess.run([cls.compiler, "-std=gnu++17", "-O1", "-w", "-I", str(APP),
                            str(APP / "LzhamCodec.cpp"), str(tmp / "main.cpp"), "-o", str(cls.binary)],
                           check=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_codec(self, data: bytes, capacity: int = 20000):
        if not self.binary:
            self.skipTest("no C++ compiler")
        tmp = pathlib.Path(self.tmp.name)
        src, out = tmp / "in.bin", tmp / "out.bin"
        out.unlink(missing_ok=True)
        src.write_bytes(data)
        result = subprocess.run([str(self.binary), str(src), str(out), str(capacity)],
                                check=True, capture_output=True, text=True)
        written = int(result.stdout.strip())
        return written, (out.read_bytes() if written > 0 else b"")

    def test_fixture_has_lzham_zlib_header(self):
        self.assertEqual(FIXTURE[0] & 15, 14)
        self.assertEqual((FIXTURE[0] << 8 | FIXTURE[1]) % 31, 0)

    def test_decodes_reference_stream(self):
        written, data = self.run_codec(FIXTURE)
        self.assertEqual(written, 20000)
        self.assertEqual(data, expected_plain())

    def test_damaged_stream_fails(self):
        damaged = bytearray(FIXTURE)
        damaged[-1] ^= 1
        written, _ = self.run_codec(bytes(damaged))
        self.assertLess(written, 0)

    def test_small_buffer_reports_status(self):
        written, _ = self.run_codec(FIXTURE, capacity=1000)
        self.assertLess(written, 0)   # a status, never a short buffer passed off as the slice


class LzhamWiringTests(unittest.TestCase):
    def test_vendored_decoder_is_complete(self):
        vendor = APP / "Vendor" / "LZHAM"
        self.assertIn("PUBLIC DOMAIN", (vendor / "LICENSE").read_text())
        unit = (APP / "LzhamCodec.cpp").read_text()
        for name in re.findall(r'#include "Vendor/LZHAM/([^"]+)"', unit):
            self.assertTrue((vendor / name).exists(), name)
        cpp = sorted(p.name for p in vendor.glob("*.cpp"))
        self.assertEqual(cpp, sorted(re.findall(r'#include "Vendor/LZHAM/([^"]+\.cpp)"', unit)))
        self.assertIn('extern "C"', unit)

    def test_libcxx_pod_fix(self):
        traits = (APP / "Vendor" / "LZHAM" / "lzham_traits.h").read_text()
        self.assertNotIn("#define LZHAM_IS_POD(T) std::__is_pod", traits)
        self.assertIn("__is_trivial(T) && __is_standard_layout(T)", traits)

    def test_project_and_bridge(self):
        project = (ROOT / "iDeck.xcodeproj" / "project.pbxproj").read_text()
        self.assertIn("LzhamCodec.cpp in Sources */,", project)
        self.assertEqual(project.count("LzhamCodec.cpp"), 6)   # build file (2), file reference (2), group, sources
        self.assertNotIn("Vendor/LZHAM", project)   # compiled through LzhamCodec.cpp only
        self.assertIn('#import "LzhamCodec.h"', (APP / "iDeck-Bridging-Header.h").read_text())

    def test_ubisoft_slices_use_it(self):
        swift = (APP / "UbisoftDownloader.swift").read_text()
        self.assertIn("ideck_lzham_decompress", swift)
        self.assertIn("UbisoftInflate.lzham(raw, expected: expected)", swift)
        self.assertNotIn("cannot read yet (LZHAM)", swift)
        self.assertNotIn("cannot read yet (LZHAM)", (APP / "Localization.swift").read_text())

    def test_language_layers(self):
        subprocess.run(["python3", str(ROOT / "scripts" / "check_language_layers.py"), str(ROOT)], check=True)


if __name__ == "__main__":
    unittest.main()
