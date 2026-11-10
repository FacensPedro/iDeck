import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from support import ROOT, repo_text


def patched_file(name):
    patch = repo_text('patches/dxmt-ios-cache-sync-reuse.patch')
    section = patch.split('diff --git a/' + name + ' b/' + name + '\n', 1)[1].split('\ndiff --git ', 1)[0]
    if 'new file mode' in section:
        return '\n'.join(line[1:] for line in section.splitlines() if line.startswith('+') and not line.startswith('+++')) + '\n'
    raise AssertionError('Expected added file ' + name)


class ShaderCacheSafetyTests(unittest.TestCase):
    def test_sqlite_trim_keeps_live_readers_and_busy_writers_safe(self):
        probe = subprocess.run(['cc', '-E', '-x', 'c', '-include', 'sqlite3.h', '-'], input='', text=True, capture_output=True)
        if probe.returncode != 0:
            if shutil.which('xcrun'):
                self.fail('SQLite headers must be available on macOS CI')
            self.skipTest('SQLite development headers unavailable')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'cache_trim.h').write_text(patched_file('src/winemetal/unix/cache_trim.h'))
            binary = root / 'cache-test'
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-I', str(root),
                            str(ROOT / 'tests/host/ShaderCacheTrimTests.c'), '-lsqlite3', '-o', str(binary)], check=True)
            subprocess.run([str(binary), str(root / 'shaders.db')], check=True)

    def test_actual_reader_methods_hold_lock_and_retry_concurrently(self):
        patch = repo_text('patches/dxmt-ios-cache-sync-reuse.patch')
        section = patch.split('diff --git a/src/dxmt/dxmt_shader_cache.hpp ', 1)[1].split('\ndiff --git ', 1)[0]
        # Reconstruct the changed method region from context and additions.
        lines = [line[1:] for line in section.splitlines() if line.startswith(('+', ' ')) and not line.startswith('+++')]
        start = next(i for i, line in enumerate(lines) if 'LockProtected<WMT::CacheReader>' in line)
        end = next(i for i in range(start, len(lines)) if 'ShaderCache(WMTMetalVersion' in lines[i])
        methods = '\n'.join(lines[start:end])
        fixture = repo_text('tests/host/ShaderCacheReaderTests.cpp').replace('/* ACTUAL_READER_METHODS */', methods)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'reader.cpp').write_text(fixture)
            binary = root / 'reader-test'
            subprocess.run(['c++', '-std=c++17', '-pthread', str(root / 'reader.cpp'), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

    def test_trim_never_unlinks_database_files(self):
        patch = repo_text('patches/dxmt-ios-cache-sync-reuse.patch')
        added = '\n'.join(line[1:] for line in patch.splitlines() if line.startswith('+') and not line.startswith('+++'))
        self.assertNotIn('unlink([dbPath', added)
        self.assertIn('wmt_trim_shader_cache(_db', added)
