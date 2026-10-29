#!/usr/bin/env python3
"""Backport Madeira's GC64 LuaJIT image substitution to the pinned wineserver."""

from pathlib import Path
import argparse
import shutil


def once(source: str, old: str, new: str, name: str) -> str:
    if source.count(old) != 1:
        raise RuntimeError(f"Unexpected pinned Madeira {name}: matching context count {source.count(old)}")
    return source.replace(old, new, 1)


def patch(madeira: Path, root: Path) -> None:
    mapping = madeira / "build/wineserver/mapping_ios.c"
    server = madeira / "build/wineserver/build.sh"
    lua_source = root / "build/wineserver/luajit_compat.c"
    if not all(p.is_file() for p in (mapping, server, lua_source)):
        raise RuntimeError("Required pinned Wine/LuaJIT sources are missing")

    source = mapping.read_text(encoding="utf-8")
    if "madeira_luajit_compat_fd" not in source:
        source = once(
            source,
            "static struct fd *mapping_get_fd( struct object *obj );",
            "static struct fd *mapping_get_fd( struct object *obj );\n"
            "extern int madeira_luajit_compat_fd( int unix_fd, off_t file_size );",
            "wineserver mapping declaration",
        )
        before = """        if (flags & SEC_IMAGE)
        {
            unsigned int err = get_image_params( mapping, st.st_size, unix_fd );
            if (!err) return mapping;
            set_error( err );
            goto error;
        }"""
        after = """        if (flags & SEC_IMAGE)
        {
            unsigned int err;
            /* Replace only x64 LuaJIT modules requiring an inaccessible low
             * 2 GB arena with the compatible GC64 interpreter build. */
            int compat_fd = madeira_luajit_compat_fd( unix_fd, st.st_size );
            if (compat_fd != -1)
            {
                struct stat compat_st;
                struct fd *compat = create_anonymous_fd( &mapping_fd_ops, compat_fd, &mapping->obj,
                                                         FILE_SYNCHRONOUS_IO_NONALERT );
                if (compat && fstat( compat_fd, &compat_st ) != -1)
                {
                    release_object( mapping->fd );
                    mapping->fd = compat;
                    unix_fd = compat_fd;
                    st = compat_st;
                }
                else if (compat) release_object( compat );
            }
            err = get_image_params( mapping, st.st_size, unix_fd );
            if (!err) return mapping;
            set_error( err );
            goto error;
        }"""
        source = once(source, before, after, "SEC_IMAGE LuaJIT hook")
        mapping.write_text(source, encoding="utf-8")

    compiler = server.read_text(encoding="utf-8")
    if '"luajit_compat:$BUILD_DIR/luajit_compat.c:luajit_compat.o"' not in compiler:
        compiler = once(
            compiler,
            '"mapping:$BUILD_DIR/mapping_ios.c:mapping.o"',
            '"mapping:$BUILD_DIR/mapping_ios.c:mapping.o"\n'
            '    "luajit_compat:$BUILD_DIR/luajit_compat.c:luajit_compat.o"',
            "wineserver patched source list",
        )
        compiler = once(
            compiler,
            '"mapping.o:mapping.o"',
            '"mapping.o:mapping.o"\n'
            '    "luajit_compat.o:luajit_compat.o"',
            "wineserver archive member replacements",
        )
        server.write_text(compiler, encoding="utf-8")
    destination = madeira / "build/wineserver/luajit_compat.c"
    shutil.copyfile(lua_source, destination)
    print("LuaJIT GC64 mapping backport applied to pinned Madeira wineserver")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--madeira", required=True, type=Path)
    args = parser.parse_args()
    patch(args.madeira, Path(__file__).resolve().parents[1])


if __name__ == "__main__":
    main()
