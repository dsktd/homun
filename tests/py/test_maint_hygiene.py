"""hygiene.py against throwaway bare clones."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
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

    def test_gone_upstream_falls_back_to_default(self):
        run(
            "git",
            "-C",
            str(self.repo),
            "update-ref",
            "refs/remotes/origin/topic",
            "main",
        )
        self.worktree("topicwt", "topic")
        g = ("git", "-C", str(self.repo), "config")
        run(*g, "remote.origin.url", str(self.repo))
        run(*g, "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")
        run(*g, "branch.topic.remote", "origin")
        run(*g, "branch.topic.merge", "refs/heads/topic")
        run(
            "git", "-C", str(self.repo), "update-ref", "-d", "refs/remotes/origin/topic"
        )
        r = self.report()
        (tree,) = [t for t in r["worktrees"] if t["branch"] == "topic"]
        self.assertEqual(tree["base"], "main")
        self.assertIn("topic", r["branches_without_upstream"])

    def test_stale_local_default_uses_origin(self):
        wt = self.worktree("featwt", "feat")
        self.commit(wt, "g", "g")
        run(
            "git",
            "-C",
            str(self.repo),
            "update-ref",
            "refs/remotes/origin/main",
            "feat",
        )
        r = self.report()
        (tree,) = [t for t in r["worktrees"] if t["branch"] == "feat"]
        self.assertEqual(tree["base"], "refs/remotes/origin/main")
        self.assertTrue(tree["merged-by-cherry"])

    def test_unseen_worktree_is_kept_and_failure_isolated(self):
        gone = self.worktree("gone", "feature/gone")
        run("rm", "-rf", str(gone))
        (tree,) = self.report()["worktrees"]
        self.assertTrue(tree["missing"])
        self.assertEqual(len(hygiene.worktrees(self.repo)), 1)
        (self.bare / "broken.git").mkdir()
        out = {r["repo"]: r for r in hygiene.scan(self.bare)}
        self.assertIn("error", out["broken.git"])
        self.assertIn("worktrees", out["demo.git"])


if __name__ == "__main__":
    unittest.main()
