# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parents[2] / "bin" / "claude-secret"


class ClaudeSecret(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = Path(self._tmp.name)
        self.inbox = self.dir / "inbox"
        self.inbox.mkdir()
        (self.inbox / "dsktd-token").write_text("ghp_SECRET")
        (self.inbox / "other").write_text("x")
        self.home = self.dir / "home"

    def run_bin(self, *args):
        env = dict(os.environ, SECRETS_INBOX=str(self.inbox), HOME=str(self.home))
        return subprocess.run(
            ["python3", str(BIN), *args],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )

    def test_take_writes_0600_and_never_prints(self):
        r = self.run_bin("take", "dsktd-token", "to", "dsktd-token")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("SECRET", r.stdout + r.stderr)
        out = self.home / ".config/gh/dsktd.token"
        self.assertEqual(out.read_text(), "ghp_SECRET")
        self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o600)

    def test_take_mechanic_inbox_token(self):
        (self.inbox / "mechanic-inbox-token").write_text("github_pat_SECRET")
        r = self.run_bin("take", "mechanic-inbox-token", "to", "mechanic-inbox-token")
        self.assertEqual(r.returncode, 0, r.stderr)
        out = self.home / "claude/.services/mechanic/inbox-token"
        self.assertEqual(out.read_text(), "github_pat_SECRET")
        self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o600)

    def test_take_keeps_a_backup(self):
        out = self.home / ".config/gh/dsktd.token"
        out.parent.mkdir(parents=True)
        out.write_text("old")
        self.assertEqual(
            self.run_bin("take", "dsktd-token", "to", str(out)).returncode, 0
        )
        bak = out.with_name("dsktd.token.bak")
        self.assertEqual(bak.read_text(), "old")
        self.assertEqual(stat.S_IMODE(bak.stat().st_mode), 0o600)
        self.assertEqual(out.read_text(), "ghp_SECRET")

    def test_refuses_other_destinations_and_names(self):
        for args in (
            ("take", "dsktd-token", "to", "/tmp/evil"),
            ("take", "dsktd-token", "to", "../x"),
            ("take", "other", "to", "other"),
            ("take", "../dsktd-token", "to", "dsktd-token"),
            ("take", "missing", "to", "missing"),
        ):
            r = self.run_bin(*args)
            self.assertEqual(r.returncode, 1, args)
            self.assertNotIn("SECRET", r.stdout + r.stderr)
        self.assertFalse((self.home / ".config/gh/dsktd.token").exists())
        self.assertFalse(Path("/tmp/evil").exists())

    def test_list_shows_names_sizes_ages_only(self):
        r = self.run_bin("list")
        self.assertEqual(r.returncode, 0)
        self.assertIn("dsktd-token  10 bytes", r.stdout)
        self.assertNotIn("SECRET", r.stdout)

    def test_help(self):
        self.assertIn("take NAME to DEST", self.run_bin("help").stdout)


if __name__ == "__main__":
    unittest.main()
