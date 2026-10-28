import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH = (ROOT / "patches/madeira-arm64ec-mach-context-return.patch").read_text()


def patched_handler():
    begin = PATCH.index("+static int ios_mach_resume_arm64ec_slowpath(")
    end = PATCH.index("+#endif", begin)
    block = PATCH[begin:end]
    lines = block.splitlines()
    if not lines or not all(line.startswith("+") for line in lines):
        raise AssertionError("Cannot extract the actual C handler from the native patch")
    return "\n".join(line[1:] for line in lines) + "\n"


SHIM = r"""
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
typedef int thread_t;
typedef unsigned mach_msg_type_number_t;
typedef uint64_t mach_vm_size_t;
typedef uint64_t mach_vm_address_t;
typedef uint32_t *thread_state_t;
typedef int kern_return_t;
#define KERN_SUCCESS 0
#define ARM_THREAD_STATE64 1
#define ARM_NEON_STATE64 2
#define CONTEXT_INTEGER 2
#define IDECK_ARM64EC_RETURN_BRK 0xd42b4b40u
typedef struct {
    uint64_t __x[29];
    uint64_t __fp,__lr,__sp,__pc;
    uint32_t __cpsr;
} arm_thread_state64_t;
typedef struct {
    uint8_t __v[32][16];
    uint32_t __fpcr, __fpsr;
} arm_neon_state64_t;
struct syscall_frame {
    uint64_t x[29];
    uint64_t fp,lr,sp,pc;
    uint32_t cpsr,restore_flags;
    uint8_t unused[32];
    uint32_t fpcr,fpsr;
    uint8_t v[32][16];
};
#define arm_thread_state64_get_pc(state) ((state).__pc)
#define __darwin_arm_thread_state64_set_sp(state,value) ((state).__sp = (value))
#define __darwin_arm_thread_state64_set_pc_fptr(state,value) ((state).__pc = (uintptr_t)(value))
static uint64_t fake_teb = 0x717ffe0000ull;
static uint64_t fake_frame_addr = 0x717fff0000ull;
static struct syscall_frame fake_frame;
static arm_thread_state64_t last_gpr;
static arm_neon_state64_t last_neon;
static int gpr_calls, neon_calls, reject_gpr, bad_opcode;
void syscall_dispatcher_return_slowpath(void) {}
static int mach_task_self(void) { return 0; }
static kern_return_t mach_vm_read_overwrite(int task, mach_vm_address_t address,
    size_t count, mach_vm_address_t destination, mach_vm_size_t *size)
{
    uint32_t insn = bad_opcode ? 0xd4200000u : IDECK_ARM64EC_RETURN_BRK;
    uintptr_t sym = (uintptr_t)syscall_dispatcher_return_slowpath;
    (void)task;
    if (address == sym + 4 && count == sizeof(insn))
        memcpy((void *)(uintptr_t)destination, &insn, count);
    else if (address == fake_teb + 0x30 && count == sizeof(fake_teb))
        memcpy((void *)(uintptr_t)destination, &fake_teb, count);
    else if (address == fake_teb + 0x378 && count == sizeof(fake_frame_addr))
        memcpy((void *)(uintptr_t)destination, &fake_frame_addr, count);
    else if (address == fake_frame_addr && count == sizeof(fake_frame))
        memcpy((void *)(uintptr_t)destination, &fake_frame, count);
    else return -1;
    *size = count;
    return KERN_SUCCESS;
}
static kern_return_t thread_set_state(thread_t thread, int which,
    thread_state_t value, mach_msg_type_number_t count)
{
    (void)thread;
    (void)count;
    if (which == ARM_THREAD_STATE64) {
        ++gpr_calls;
        if (reject_gpr) return -1;
        memcpy(&last_gpr, value, sizeof(last_gpr));
    } else if (which == ARM_NEON_STATE64) {
        ++neon_calls;
        memcpy(&last_neon, value, sizeof(last_neon));
    } else return -1;
    return KERN_SUCCESS;
}
"""

TESTS = r"""
int main(void)
{
    arm_thread_state64_t original = {0};
    arm_neon_state64_t old_neon = {0};
    uintptr_t symbol = (uintptr_t)syscall_dispatcher_return_slowpath;
    original.__pc = symbol + 4;
    original.__cpsr = 0x02000000u;
    fake_frame.pc = 0x140012000ull;
    fake_frame.sp = 0x717ffeb000ull;
    fake_frame.fp = 0x717ffe9000ull;
    fake_frame.lr = 0x140024000ull;
    fake_frame.x[16] = 0x1234567810ull;
    fake_frame.x[17] = 0x8765432110ull;
    fake_frame.x[18] = fake_teb;
    fake_frame.x[0] = 0xfade0001ull;
    fake_frame.restore_flags = CONTEXT_INTEGER;
    fake_frame.cpsr = 0xa0000000u;
    fake_frame.fpcr = 0x1234;
    fake_frame.fpsr = 0x5678;
    fake_frame.v[4][0] = 0x7f;
    assert(ios_mach_resume_arm64ec_slowpath(42, fake_teb, &original,
           68, &old_neon, 136, 1) == 1);
    assert(gpr_calls == 1 && neon_calls == 1);
    assert(last_gpr.__x[16] == fake_frame.x[16]);
    assert(last_gpr.__x[17] == fake_frame.x[17]);
    assert(last_gpr.__x[18] == fake_teb);
    assert(last_gpr.__x[0] == fake_frame.x[0]);
    assert(last_gpr.__sp == fake_frame.sp);
    assert(last_gpr.__pc == fake_frame.pc);
    assert(last_gpr.__cpsr == (0xa0000000u | 0x02000000u));
    assert(last_neon.__fpcr == 0x1234);
    assert(last_neon.__fpsr == 0x5678);
    assert(last_neon.__v[4][0] == 0x7f);

    bad_opcode = 1;
    assert(!ios_mach_resume_arm64ec_slowpath(42, fake_teb, &original,
            68, &old_neon, 136, 1));
    bad_opcode = 0;
    original.__pc = symbol + 300;
    assert(!ios_mach_resume_arm64ec_slowpath(42, fake_teb, &original,
            68, &old_neon, 136, 1));
    original.__pc = symbol + 4;
    assert(!ios_mach_resume_arm64ec_slowpath(42, 0x1000, &original,
            68, &old_neon, 136, 1));
    fake_frame.restore_flags = 0;
    assert(!ios_mach_resume_arm64ec_slowpath(42, fake_teb, &original,
            68, &old_neon, 136, 1));
    fake_frame.restore_flags = CONTEXT_INTEGER;
    fake_frame.pc = 0;
    assert(!ios_mach_resume_arm64ec_slowpath(42, fake_teb, &original,
            68, &old_neon, 136, 1));
    fake_frame.pc = 0x140012000ull;
    fake_frame.x[18] = 0xdeadbeef;
    assert(!ios_mach_resume_arm64ec_slowpath(42, fake_teb, &original,
            68, &old_neon, 136, 1));
    fake_frame.x[18] = fake_teb;
    reject_gpr = 1;
    assert(!ios_mach_resume_arm64ec_slowpath(42, fake_teb, &original,
            68, &old_neon, 136, 1));
    assert(neon_calls == 3); /* new attempt + rollback */
    puts("PASS: actual ARM64EC Mach context handler preserves x16/x17/x18, PC/SP, NZCV and NEON");
    return 0;
}
"""


APPLE_MACH_SHIM = r"""
#define _DARWIN_C_SOURCE
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/arm/thread_status.h>
#include <mach/thread_act.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define CONTEXT_INTEGER 2
#define IDECK_ARM64EC_RETURN_BRK 0xd42b4b40u
#define arm_thread_state64_get_pc(st) __darwin_arm_thread_state64_get_pc(st)
struct syscall_frame {
    uint64_t x[29];
    uint64_t fp,lr,sp,pc;
    uint32_t cpsr,restore_flags;
    uint8_t unused[32];
    uint32_t fpcr,fpsr;
    uint8_t v[32][16];
};
void syscall_dispatcher_return_slowpath(void);
"""

class ARM64ECMachCompiledTests(unittest.TestCase):
    def test_handler_compiles_against_real_iphoneos_mach_headers(self):
        xcrun = shutil.which("xcrun")
        if xcrun is None:
            self.skipTest("Requires Xcode on a macOS runner")
        sdk = subprocess.check_output(
            [xcrun, "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
        with tempfile.TemporaryDirectory(prefix="ideck-apple-mach-arm64ec-") as tmp:
            source = pathlib.Path(tmp) / "resume-ios.c"
            source.write_text(APPLE_MACH_SHIM + patched_handler())
            checked = subprocess.run([
                xcrun, "--sdk", "iphoneos", "clang",
                "-target", "arm64-apple-ios18.0",
                "-isysroot", sdk, "-std=c11", "-Wall", "-Wextra",
                "-Werror", "-Wno-unused-function", "-fsyntax-only",
                str(source)],
                capture_output=True, text=True)
            self.assertEqual(
                checked.returncode, 0,
                "iPhoneOS Mach header compilation rejected native ARM64EC handler:\\n" +
                checked.stdout + checked.stderr)

    def test_actual_native_mach_handler_with_mocked_kernel_calls(self):
        compiler = shutil.which("clang")
        self.assertIsNotNone(compiler, "Clang is required")
        with tempfile.TemporaryDirectory(prefix="ideck-arm64ec-context-") as tmp:
            source = pathlib.Path(tmp) / "resume.c"
            binary = pathlib.Path(tmp) / "resume"
            source.write_text(SHIM + patched_handler() + TESTS)
            subprocess.run(
                [compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                 "-O1", str(source), "-o", str(binary)],
                check=True, capture_output=True, text=True)
            subprocess.run([str(binary)], check=True,
                           capture_output=True, text=True)


if __name__ == "__main__":
    unittest.main()
