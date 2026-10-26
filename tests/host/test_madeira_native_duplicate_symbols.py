import importlib.util
import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LINKER = ROOT / "scripts" / "link_madeira_native.sh"
HOST_SINK = ROOT / "iDeck" / "NativeRuntime" / "MadeiraHostCallbacks.m"

SPEC = importlib.util.spec_from_file_location(
    "symbol_checker", ROOT / "scripts" / "report_madeira_symbol_collisions.py"
)
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


class MadeiraNativeDuplicateSymbolsTests(unittest.TestCase):
    def test_d3d12_canary_is_only_owned_by_dxmt(self):
        source = LINKER.read_text(encoding="utf-8")
        self.assertIn('"$APP/libdxmt_combined.a"', source)
        self.assertIn('"_madeira_d3d12_canary_run"', source)
        self.assertIn('"_madeira_d3d12_canary_run_log"', source)
        self.assertNotIn('OBJS+=("$CANARY_OBJ")', source)
        self.assertNotIn('CANARY_OBJ="$OUT/obj/msc_canary.o"', source)


    def test_dxmt_canary_awk_preflight_is_executable(self):
        source = LINKER.read_text(encoding="utf-8")
        delimiter = 'nm -gU "$APP/libdxmt_combined.a" | awk \''
        start = source.index(delimiter) + len(delimiter)
        end = source.index("\\n'; then", start)
        program = source[start:end]
        canary_run = "0000000000000000 T _madeira_d3d12_canary_run\\n"
        canary_log = "0000000000000000 T _madeira_d3d12_canary_run_log\\n"
        test_cases = (
            (canary_run + canary_log, 0),
            (canary_run, 1),
            (canary_log, 1),
            ("0000000000000000 T _unrelated_symbol\\n", 1),
        )
        for symbols, expected in test_cases:
            with self.subTest(symbols=symbols):
                result = subprocess.run(
                    ["awk", program],
                    input=symbols,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(
                    result.returncode, expected,
                    f"awk preflight failed: {result.stderr}",
                )
                self.assertEqual(result.stderr, "")

    def test_no_second_wine_ui_log(self):
        linker = LINKER.read_text(encoding="utf-8")
        callback = HOST_SINK.read_text(encoding="utf-8")
        self.assertNotIn('OBJS+=("$OUT/obj/MadeiraHostCallbacks.o")', linker)
        self.assertNotRegex(callback, r"\bvoid\s+wine_ui_log\s*\(")
        self.assertIn("ideck_wine_os_log_sink", callback)

    def test_collision_parser_ignores_undefined_and_weak_symbols(self):
        samples = {
            "libbridge.a": (
                "libbridge.a(canary.o):\n"
                "00000000 T _canary\n"
                "00000001 W _shared_weak\n"
                "         U _external\n"
            ),
            "libdxmt.a": (
                "libdxmt.a(canary.o):\n"
                "00000012 T _canary\n"
                "00000014 W _shared_weak\n"
                "         U _external\n"
            ),
        }
        self.assertEqual(
            checker.collisions_from_outputs(samples),
            {"_canary": ["libbridge.a(canary.o)", "libdxmt.a(canary.o)"]},
        )

    def test_collision_parser_supports_inline_nm_format(self):
        result = list(checker.parse_defined_symbols(
            "/work/libwine.a(server.o): 0000000000000000 T _server_api\n",
            "libwine.a",
        ))
        self.assertEqual(result, [("_server_api", "libwine.a(server.o)")])

    def test_probe_and_collision_report_are_part_of_native_link(self):
        source = LINKER.read_text(encoding="utf-8")
        self.assertIn('xcrun --sdk iphoneos nm -gU "$APP/libdxmt_combined.a"', source)
        self.assertIn('scripts/report_madeira_symbol_collisions.py', source)
        self.assertIn('FLAGS+=(-force_load "${ARCHIVES[0]}" -force_load "${ARCHIVES[11]}")', source)


if __name__ == "__main__":
    unittest.main()
