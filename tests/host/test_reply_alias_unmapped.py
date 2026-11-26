"""Reply data goes through the JIT-pool RW alias only when that alias is mapped (2.16.2)."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATCH = (ROOT / "patches" / "madeira-reply-alias-unmapped.patch").read_text()
SERIES = (ROOT / "patches" / "series.txt").read_text()


class ReplyAliasUnmapped(unittest.TestCase):
    def test_in_early_group(self):
        self.assertIn("early     .      madeira-reply-alias-unmapped.patch", SERIES)
        self.assertIn("+++ b/build/ntdll-unix/server_ios.c", PATCH)

    def test_alias_checked_before_use(self):
        self.assertIn("+        if ((rw = ios_reply_rw_alias( dst )) && ios_reply_host_writable( rw, n ))", PATCH)
        self.assertIn("+        if (!alias || !ios_reply_host_writable( alias, IOS_REPLY_PAGE )) continue;", PATCH)


if __name__ == "__main__":
    unittest.main()
