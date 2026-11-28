# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parents[2] / "bin/homun-land"
LEASE = Path(__file__).resolve().parents[2] / "bin/homun-lease"


def git(cwd, *a):
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *a], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class LandTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-b", "main")
        self.commit(self.repo, "a", "1")
        self.wt = self.tmp / "wt"
        git(self.repo, "worktree", "add", self.wt, "-b", "feat")
        self.env = {**os.environ, "REPO": str(self.repo), "LEASE_FILE": str(self.tmp / "lease")}

    def commit(self, where, name, text):
        (Path(where) / name).write_text(text)
        git(where, "add", name)
        git(where, "commit", "-m", name)

    def land(self, *a):
        return subprocess.run([BIN, *a], env=self.env, capture_output=True, text=True)

    def free(self):
        return not (self.tmp / "lease").exists()

    def test_lands_after_main_moved(self):
        self.commit(self.wt, "f", "x")
        self.commit(self.repo, "b", "2")
        r = self.land("feat", "wait", "0")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue((self.repo / "f").exists() and (self.repo / "b").exists())
        self.assertEqual(git(self.repo, "log", "--format=%s", "-1"), "f")
        self.assertTrue(self.free())

    def test_unparsable_elisp_is_refused(self):
        (self.wt / "container/emacs").mkdir(parents=True)
        self.commit(self.wt, "container/emacs/x.el", "(defun a ()\n  (b)\n")
        r = self.land("feat", "wait", "0")
        self.assertEqual(r.returncode, 1)
        self.assertIn("x.el:", r.stderr)
        self.assertFalse((self.repo / "container").exists())
        self.assertTrue(self.free())

    def test_conflict_aborts_and_releases(self):
        self.commit(self.wt, "a", "mine")
        self.commit(self.repo, "a", "theirs")
        r = self.land("feat", str(self.wt))
        self.assertEqual(r.returncode, 1)
        self.assertIn("rebase", r.stderr)
        self.assertEqual(git(self.wt, "status", "--porcelain"), "")
        self.assertTrue(self.free())

    def test_held_lease_fails_without_touching_it(self):
        subprocess.run(["python3", LEASE, "take", "mechanic", "x"], env=self.env, check=True)
        r = self.land("feat", "wait", "0")
        self.assertEqual(r.returncode, 1)
        self.assertIn("held by mechanic", r.stderr)
        self.assertFalse(self.free())

    def test_dirty_worktree_stops_before_lease(self):
        self.commit(self.wt, "f", "x")
        (self.wt / "f").write_text("dirty")
        self.assertEqual(self.land("feat").returncode, 1)
        self.assertTrue(self.free())

    def test_usage(self):
        self.assertEqual(self.land().returncode, 2)


if __name__ == "__main__":
    unittest.main()
