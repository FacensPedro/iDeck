import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = (ROOT / "patches/madeira-arm64ec-mach-context-return.patch").read_text(encoding="utf-8")
FETCH = (ROOT / "scripts/fetch_madeira_sources.sh").read_text(encoding="utf-8")
BUILD = (ROOT / "scripts/build_ipa.sh").read_text(encoding="utf-8")
KIT = (ROOT / "scripts/madeira_native_kit.py").read_text(encoding="utf-8")
WORKFLOW = (ROOT / ".github/workflows/ios.yml").read_text(encoding="utf-8")


class ARM64ECMachSlowpathTests(unittest.TestCase):
    def test_exact_pinned_wine_source_is_patched_on_native_build(self):
        self.assertIn("build/ntdll-unix/signal_arm64_ios.c", PATCH)
        self.assertEqual(PATCH.count("diff --git"), 1)
        self.assertEqual(PATCH.count("\n@@ -"), 4)
        self.assertIn("git -C \"$DEST\" apply --check \"$ARM64EC_PATCH\"", FETCH)
        self.assertIn("git -C \"$DEST\" apply \"$ARM64EC_PATCH\"", FETCH)
        self.assertIn("brk #0x5a5a", FETCH)
        self.assertIn('bash "$MD/build/ntdll-unix/build.sh"',
                      (ROOT / "scripts/build_madeira_components.sh").read_text())

    def test_reserved_mach_breakpoint_is_scoped_to_registered_wine_thread(self):
        self.assertIn("+    __asm__ volatile( \"brk #0x5a5a\" ::: \"memory\" );", PATCH)
        self.assertIn("+    __builtin_unreachable();", PATCH)
        self.assertIn("IDECK_ARM64EC_RETURN_BRK 0xd42b4b40u", PATCH)
        self.assertIn("req->exception == EXC_BREAKPOINT &&", PATCH)
        self.assertIn("pc < symbol || pc - symbol >= 256", PATCH)
        self.assertIn("insn != IDECK_ARM64EC_RETURN_BRK", PATCH)
        self.assertIn("teb_self != teb", PATCH)
        self.assertIn("teb + 0x378", PATCH)
        self.assertIn("frame_ptr & 15", PATCH)
        self.assertIn("frame.restore_flags & CONTEXT_INTEGER", PATCH)
        self.assertIn("goto ios_mach_send_reply;", PATCH)
        self.assertIn("ios_mach_send_reply:", PATCH)
        self.assertNotIn("raise( SIGILL );", PATCH)

    def test_guest_integer_neon_and_x18_are_restored_without_signal(self):
        self.assertIn("next.__x[i] = frame.x[i]", PATCH)
        self.assertIn("next.__x[18] = teb;", PATCH)
        self.assertIn("__darwin_arm_thread_state64_set_sp( next, frame.sp );", PATCH)
        self.assertIn("__darwin_arm_thread_state64_set_pc_fptr( next,", PATCH)
        self.assertIn("next.__cpsr = (original->__cpsr & ~0xf0000000u)", PATCH)
        self.assertIn("memcpy( next_neon.__v, frame.v, sizeof(frame.v) );", PATCH)
        self.assertIn("next_neon.__fpcr = frame.fpcr", PATCH)
        self.assertIn("next_neon.__fpsr = frame.fpsr", PATCH)
        self.assertIn("thread_set_state( thread, ARM_NEON_STATE64", PATCH)
        self.assertIn("thread_set_state( thread, ARM_THREAD_STATE64", PATCH)
        self.assertIn("Roll back the NEON state", PATCH)
        self.assertIn("+    raise( SIGUSR2 );", PATCH)\n        self.assertIn("+#else", PATCH)

    def test_prebuilt_kits_cannot_silently_undo_native_fix(self):
        self.assertIn("arm64ec_context_patch_sha256", KIT)
        self.assertIn("ARM64EC Mach context patch mismatch", KIT)
        self.assertIn("madeira_native_kit.py inspect --archive", WORKFLOW)
        self.assertIn("madeira_native_kit.py inspect --archive", BUILD)
        self.assertIn("'patches/*'", WORKFLOW)

    def test_wine_dispatcher_caller_and_return_logic_are_both_changed(self):
        self.assertIn("syscall_dispatcher_return_slowpath(void)", PATCH)
        self.assertIn("ios_mach_resume_arm64ec_slowpath(", PATCH)
        self.assertIn("frame.x[16]", PATCH)
        self.assertIn("frame.x[17]", PATCH)
        self.assertEqual(PATCH.count("+    __asm__ volatile( \"brk #0x5a5a\""), 1)
        self.assertIn("EXC_BREAKPOINT", PATCH)
        self.assertIn("mach_vm_read_overwrite", PATCH)

    def test_patch_hunks_have_self_consistent_line_counts(self):
        blocks = re.split(r"(?=^@@ -)", PATCH, flags=re.M)
        hunks = [block for block in blocks if block.startswith("@@ -")]
        self.assertEqual(len(hunks), 4)
        for block in hunks:
            header, *lines = block.splitlines()
            match = re.fullmatch(r"@@ -(\d+),(\d+) \+(\d+),(\d+) @@", header)
            self.assertIsNotNone(match)
            count_removed = sum(line[0] != "+" for line in lines)
            count_added = sum(line[0] != "-" for line in lines)
            self.assertEqual(count_removed, int(match.group(2)))
            self.assertEqual(count_added, int(match.group(4)))


if __name__ == "__main__":
    unittest.main()
