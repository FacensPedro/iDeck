"""Memory+ status with GetMoreRam, the JIT method step and the child environment patch."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def text(path: str) -> str:
    return (ROOT / path).read_text()


class MemoryPlusTests(unittest.TestCase):
    def test_status_comes_from_the_signing_profile_and_the_address_space(self):
        source = text("iDeck/AddressSpaceCheck.swift")
        self.assertIn("enum MemoryPlus", source)
        self.assertIn('"com.apple.developer.kernel.increased-memory-limit"', source)
        self.assertIn('forResource: "embedded", withExtension: "mobileprovision"', source)
        self.assertIn("AddressSpaceCheck.hasGuestWindow ? .granted : .missing", source)
        self.assertIn('URL(string: "https://github.com/hugeBlack/GetMoreRam")!', source)

    def test_settings_show_the_state_and_getmoreram_steps(self):
        settings = text("iDeck/SettingsView.swift")
        self.assertIn("memoryPlusSection", settings)
        self.assertIn("MemoryPlus.getMoreRamSteps", settings)
        self.assertIn('Link(tr("Open GetMoreRam"), destination: MemoryPlus.getMoreRamURL)', settings)
        self.assertIn("UIPasteboard.general.string = MemoryPlus.appID", settings)
        self.assertNotIn("Requested in IPA", settings)

    def test_new_strings_are_translated(self):
        table = text("iDeck/Localization.swift")
        for step in ("Tap Add Increased Memory Limit.", "Open GetMoreRam", "Increased Memory Limit"):
            self.assertIn(f'"{step}": ["pt":', table)


class JITSetupStepTests(unittest.TestCase):
    def step(self) -> str:
        view = text("iDeck/MainView.swift")
        return view[view.index("    private var jitStep: some View {"):view.index("    // MARK: - Summary")]

    def test_the_step_only_chooses_the_method(self):
        step = self.step()
        self.assertIn('Text("StikDebug").tag("stikdebug")', step)
        self.assertIn('Text("Built-in").tag("builtIn")', step)
        for gone in ("Enable JIT", "Reconnect debugger", "requestBuiltInJIT", "requestStikDebugJIT"):
            self.assertNotIn(gone, step)

    def test_built_in_still_imports_its_pairing_file(self):
        self.assertIn("pairingImporterPresented = true", self.step())


class SpawnEnvironmentTests(unittest.TestCase):
    SOURCE = (
        "static NTSTATUS spawn_process( void )\n{\n#ifdef WINE_IOS\n"
        "    /* iOS: create a thread instead of fork+exec */\n"
        "    if (winedebug) putenv( winedebug );\n    return 0;\n#else\n"
        "            if (winedebug) putenv( winedebug );\n#endif\n}\n"
    )

    def apply(self, source: str):
        spec = importlib.util.spec_from_file_location("spawn_env", ROOT / "scripts/apply_madeira_spawn_env.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "build/ntdll-unix/process_ios.c"
            path.parent.mkdir(parents=True)
            path.write_text(source)
            first = module.main(folder)
            second = module.main(folder) if first == 0 else None
            return first, second, path.read_text()

    def test_the_ios_child_gets_a_copy_and_the_fork_path_is_untouched(self):
        first, second, result = self.apply(self.SOURCE)
        self.assertEqual((first, second), (0, 0))
        ios, fork = result.split("#else")
        self.assertNotIn("putenv", ios)
        self.assertIn("setenv( winedebug, value + 1, 1 );", ios)
        self.assertIn("putenv( winedebug )", fork)

    def test_an_unknown_source_is_an_error(self):
        self.assertEqual(self.apply("int main(void) { return 0; }\n")[0], 2)

    def test_the_fetch_applies_it(self):
        self.assertIn('python3 "$ROOT/scripts/apply_madeira_spawn_env.py" "$DEST"', text("scripts/fetch_madeira_sources.sh"))


if __name__ == "__main__":
    unittest.main()
