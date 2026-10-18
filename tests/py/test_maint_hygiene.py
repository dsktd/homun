"""hygiene.py against throwaway bare clones."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(
    0, str(Path(__file__).resolve().parents[2] / "container/services/maint")
)
import hygiene

IDENT = ["-c", "user.name=t", "-c", "user.email=t@t"]


def run(*args):
    subprocess.run(args, check=True, capture_output=True)


class Hygiene(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.bare = self.dir / "bare"
        self.bare.mkdir()
        self.repo = self.bare / "demo.git"
        run("git", "init", "-q", "--bare", "-b", "main", str(self.repo))
        seed = self.dir / "seed"
        run("git", "init", "-q", "-b", "main", str(seed))
        self.commit(seed, "f", "x")
        run("git", "-C", str(seed), "push", "-q", str(self.repo), "main")

    def commit(self, path, name, text):
        (Path(path) / name).write_text(text)
        run("git", "-C", str(path), "add", name)
        run("git", "-C", str(path), *IDENT, "commit", "-qm", name)

    def worktree(self, name, branch):
        path = self.dir / name
        run(
            *("git", "-C", str(self.repo), "worktree", "add", "-q"),
            *("-b", branch, str(path), "main"),
        )
        return path

    def report(self):
        (out,) = hygiene.scan(self.bare)
        return out

    def test_dirty_merged_unmerged(self):
        dirty = self.worktree("dirty", "feature/dirty")
        (dirty / "f").write_text("changed")
        done = self.worktree("done", "feature/done")
        self.commit(done, "g", "g")
        run("git", "-C", str(self.repo), "branch", "-f", "main", "feature/done")
        run("git", "-C", str(self.repo), "branch", "spare", "main~1")
        r = self.report()
        trees = {t["branch"]: t for t in r["worktrees"]}
        self.assertTrue(trees["feature/dirty"]["dirty"])
        self.assertFalse(trees["feature/done"]["dirty"])
        self.assertTrue(trees["feature/done"]["merged-by-cherry"])
        self.assertEqual(trees["feature/done"]["ahead"], 0)
        self.assertEqual(trees["feature/dirty"]["behind"], 1)
        orphans = {
            b["branch"]: b["merged-by-cherry"] for b in r["branches_without_worktree"]
        }
        self.assertEqual(orphans, {"spare": True})
        self.assertIn("spare", r["branches_without_upstream"])

    def test_unmerged_branch(self):
        wip = self.worktree("wipwt", "wip")
        self.commit(wip, "w", "w")
        run("git", "-C", str(self.repo), "worktree", "remove", "--force", str(wip))
        r = self.report()
        self.assertEqual(
            r["branches_without_worktree"],
            [{"branch": "wip", "merged-by-cherry": False}],
        )
        line = next(hygiene.summary([json.dumps(r)]))
        self.assertEqual(
            line, "demo.git: 0 worktrees, 0 dirty, 0 merged, 1 unmerged branches"
        )

    def test_prune_and_failure(self):
        gone = self.worktree("gone", "feature/gone")
        run("rm", "-rf", str(gone))
        self.assertEqual(self.report()["worktrees"], [])
        (self.bare / "broken.git").mkdir()
        out = {r["repo"]: r for r in hygiene.scan(self.bare)}
        self.assertIn("error", out["broken.git"])
        self.assertIn("worktrees", out["demo.git"])


if __name__ == "__main__":
    unittest.main()
