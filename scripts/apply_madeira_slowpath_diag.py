#!/usr/bin/env python3
"""Say why the ARM64EC context-return BRK was refused.

patches/madeira-arm64ec-mach-context-return.patch makes Wine's
syscall_dispatcher_return_slowpath a reserved `brk #0x5a5a`, which the Mach
exception thread turns into a full context restore (ios_mach_resume_arm64ec_slowpath).
When one of its checks fails the breakpoint is forwarded as an illegal instruction and
the Windows process ends with 0xC000001D at that address, with nothing in the log
about which check it was.  32-bit (WoW64) Direct3D 9 games end exactly there, right
after their first OutputDebugString.

Each refusal of the exact reserved BRK now logs its reason and the values it tested
(the first 16).  Nothing about what is accepted changes.
"""
import sys
from pathlib import Path

MARKER = "ideck_slowpath_refused"
HELPER = '''/* iDeck: the reserved BRK was recognised but its context was not restored. */
static int ideck_slowpath_refused( const char *why, uint64_t a, uint64_t b, uint64_t c, uint64_t d )
{
    static volatile unsigned refused;
    if (__sync_add_and_fetch( &refused, 1 ) <= 16)
        dprintf( 2, "[arm64ec-context] error: BRK #0x5a5a context return refused (%s) "
                    "a=%#llx b=%#llx c=%#llx d=%#llx\\n", why,
                 (unsigned long long)a, (unsigned long long)b,
                 (unsigned long long)c, (unsigned long long)d );
    return 0;
}

'''
FUNCTION = "static int ios_mach_resume_arm64ec_slowpath( thread_t thread, uintptr_t teb,"
EDITS = (
    ('''    if (!have_neon || !teb || teb < 0x100000000ull || (teb & 0xfff) ||
        pc < symbol || pc - symbol >= 256 || (pc & 3))
        return 0;
''', '''    if (pc < symbol || pc - symbol >= 256 || (pc & 3))
        return 0;
'''),
    ('''        got != sizeof(insn) || insn != IDECK_ARM64EC_RETURN_BRK)
        return 0;
''', '''        got != sizeof(insn) || insn != IDECK_ARM64EC_RETURN_BRK)
        return 0;
    /* From here on it is the reserved BRK: a refusal is worth a line. */
    if (!have_neon || !teb || teb < 0x100000000ull || (teb & 0xfff))
        return ideck_slowpath_refused( "thread: a=have_neon b=teb", have_neon, teb, 0, 0 );
'''),
    ('''            &got ) != KERN_SUCCESS || got != sizeof(teb_self) || teb_self != teb)
        return 0;
''', '''            &got ) != KERN_SUCCESS || got != sizeof(teb_self) || teb_self != teb)
        return ideck_slowpath_refused( "teb self: a=teb b=teb->Self", teb, teb_self, 0, 0 );
'''),
    ('''        frame_ptr < 0x100000000ull || (frame_ptr & 15))
        return 0;
''', '''        frame_ptr < 0x100000000ull || (frame_ptr & 15))
        return ideck_slowpath_refused( "frame pointer: a=teb b=syscall_frame", teb, frame_ptr, 0, 0 );
'''),
    ('''        got != sizeof(frame))
        return 0;
''', '''        got != sizeof(frame))
        return ideck_slowpath_refused( "frame unreadable: a=syscall_frame b=bytes", frame_ptr, got, 0, 0 );
'''),
    ('''        (frame.x[18] && frame.x[18] != teb))
        return 0;
''', '''        (frame.x[18] && frame.x[18] != teb))
        return ideck_slowpath_refused( "frame: a=restore_flags b=pc c=sp d=x18", frame.restore_flags,
                                       frame.pc, frame.sp, frame.x[18] );
'''),
)


def main(root: str) -> int:
    path = Path(root) / "build/ntdll-unix/signal_arm64_ios.c"
    text = path.read_text()
    if MARKER in text:
        print("signal_arm64_ios.c: context-return refusals already logged")
        return 0
    if text.count(FUNCTION) != 1:
        print("ERROR: signal_arm64_ios.c: ios_mach_resume_arm64ec_slowpath not found", file=sys.stderr)
        return 2
    # Only this function's own checks: the same lines may exist elsewhere in the file.
    start = text.index(FUNCTION)
    end = text.index("\n}\n", start) + 3
    body = text[start:end]
    for old, new in EDITS:
        if body.count(old) != 1:
            print("ERROR: signal_arm64_ios.c: unexpected context-return check:\n" + old, file=sys.stderr)
            return 2
        body = body.replace(old, new)
    path.write_text(text[:start] + HELPER + body + text[end:])
    print("signal_arm64_ios.c: context-return refusals are logged with their reason")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "vendor/Madeira"))
