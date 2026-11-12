import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VIEW = (ROOT / "iDeck/BugReportView.swift").read_text()


def patterns():
    block = VIEW[VIEW.index("enum MissingModuleScanner"):]
    return re.findall(r'\(#"(.*?)"#,', block)


class MissingDllReportTests(unittest.TestCase):
    def test_report_line(self):
        self.assertIn('lines.append("Missing DLLs: " + missingModules)', VIEW)
        self.assertIn("missing = MissingModuleScanner.summary(text)", VIEW)

    def match(self, line):
        for pattern in patterns():
            m = re.search(pattern, line, re.I)
            if m:
                return m.groups()
        return None

    def test_wine_messages_are_recognized(self):
        self.assertEqual(self.match(r'0024:err:module:import_dll Library MSVCR120.dll (which is needed by L"C:\\Game\\game.exe") not found')[0], "MSVCR120.dll")
        self.assertEqual(self.match(r'0024:warn:file:NtCreateFile L"\\??\\C:\\windows\\system32\\xinput1_4.dll" not found (c0000034)'), ("xinput1_4.dll",))
        self.assertEqual(self.match(r'No implementation for kernel32.dll.GetFoo imported from L"C:\\x\\a.dll", setting to 0x1')[:2], ("kernel32.dll", "GetFoo"))

    def test_the_game_folder_probe_is_not_a_missing_dll(self):
        self.assertIsNone(self.match(r'0024:warn:file:NtCreateFile L"\\??\\C:\\Program Files\\EA Games\\Dragon Age Inquisition\\msvcrt.dll" not found (c0000034)'))


if __name__ == "__main__":
    unittest.main()
