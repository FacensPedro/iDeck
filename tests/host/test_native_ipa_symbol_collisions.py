"""Regression checks for the full native IPA linker collisions from build.log."""
import importlib.util
from pathlib import Path
import shutil
import sys
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/prepare_madeira_wine_link.py"
KIT = (ROOT / "scripts/madeira_native_kit.py").read_text(encoding="utf-8")
SOURCE_LINKER = (ROOT / "scripts/link_madeira_native.sh").read_text(encoding="utf-8")
HEADER = (ROOT / "iDeck/SwiftSteam/zstd_edu.h").read_text(encoding="utf-8")
ZSTD_SOURCE = ROOT / "iDeck/SwiftSteam/zstd_edu.c"

sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("wine_link_prep", SCRIPT)
wine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wine)


class NativeIPADuplicateSymbolsTests(unittest.TestCase):
    def test_namespaces_private_wine_overlap_only(self):
        client = wine.symbols_from_nm(
            "libntdll_unix.a(server.o):\n"
            "0000000000000000 T _internal_conflict\n"
            "0000000000000010 T _ntdll_client_api\n",
            "libntdll_unix.a",
        )
        server = wine.symbols_from_nm(
            "libwineserver.a(registry.o):\n"
            "0000000000000000 T _internal_conflict\n"
            "libwineserver.a(request_ios.o):\n"
            "0000000000000000 T _internal_request\n",
            "libwineserver.a",
        )
        self.assertEqual(wine.conflicts_to_namespace(client, server), ["_internal_conflict"])
        self.assertEqual(
            wine.conflicts_to_namespace(client, {"_server_unique": {"libwineserver.a(registry.o)"}}),
            [],
        )

    def test_refuses_unknown_wine_owners_and_public_abi(self):
        client = {"_overlap": {"libntdll_unix.a(server.o)"}}
        for owner in ("mapping.o", "server.o", "other.o"):
            with self.subTest(owner=owner):
                with self.assertRaises(wine.LinkArchiveError):
                    wine.conflicts_to_namespace(client, {"_overlap": {"libwineserver.a(" + owner + ")"}})
        with self.assertRaises(wine.LinkArchiveError):
            wine.conflicts_to_namespace(
                {"_wine_server_call": {"libntdll_unix.a(server.o)"}},
                {"_wine_server_call": {"libwineserver.a(registry.o)"}},
            )

    def test_original_kit_is_not_overwritten_and_linker_uses_copy(self):
        self.assertIn('scripts/prepare_madeira_wine_link.py', SOURCE_LINKER)
        self.assertIn('ARCHIVES[8]="$APP/libwineserver_ideck_link.a"', SOURCE_LINKER)
        self.assertIn('normalized = archive_root / "archives/libwineserver_ideck_link.a"', KIT)
        self.assertIn('subprocess.run(', KIT)
        self.assertIn('temp.replace(output)', KIT)
        self.assertLess(KIT.index("temp.replace(output)"), KIT.index("prepare_madeira_wine_link.py"))
        self.assertIn('os.replace(output, destination)', SCRIPT.read_text())

    def test_educational_zstd_does_not_export_libraries_zstd_functions(self):
        self.assertIn("#define ZSTD_decompress ideck_edu_zstd_decompress", HEADER)
        self.assertIn("#define ZSTD_decompress_with_dict ideck_edu_zstd_decompress_with_dict", HEADER)
        self.assertIn("#define ZSTD_get_decompressed_size ideck_edu_zstd_get_decompressed_size", HEADER)
        compiler = shutil.which("clang") or shutil.which("cc")
        nm = shutil.which("nm")
        if not compiler or not nm:
            self.skipTest("Native C compiler/nm unavailable")
        with tempfile.TemporaryDirectory() as tmp:
            obj = Path(tmp) / "zstd_edu.o"
            result = subprocess.run(
                [compiler, "-std=c11", "-c", str(ZSTD_SOURCE), "-o", str(obj)],
                capture_output=True, text=True, timeout=90,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            symbols = subprocess.run(
                [nm, "-g", str(obj)], capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(symbols.returncode, 0, symbols.stderr)
            defined = [
                line.strip().split()[-1].lstrip("_")
                for line in symbols.stdout.splitlines()
                if len(line.strip().split()) >= 3 and line.strip().split()[-2] in ("T", "D", "B")
            ]
            self.assertIn("ideck_edu_zstd_decompress", defined)
            self.assertIn("zstd_safe_decompress", defined)
            self.assertNotIn("ZSTD_decompress", defined)


if __name__ == "__main__":
    unittest.main()
