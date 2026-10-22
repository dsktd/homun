"""bin/claude-gardener: proposals and the never-touch rules, against temp repos only."""

import json
import os
import re
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parents[2] / "bin/claude-gardener"
OLD = time.time() - 30 * 86400


def sh(*args, cwd=None):
    subprocess.run(
        ["git", *args],
        cwd=cwd,
        check=True,
        capture_output=True,
        env={
            **os.environ,
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@t",
        },
    )


def age(path, when=OLD):
    for dirpath, dirs, files in os.walk(path):
        for n in [*dirs, *files]:
            os.utime(os.path.join(dirpath, n), (when, when), follow_symlinks=False)
    os.utime(path, (when, when), follow_symlinks=False)


class Gardener(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = Path(os.path.realpath(self.tmp.name))
        self.root = t / "claude"
        self.scratch = t / "scratch"
        self.gdir = t / "gardener"
        self.proc = t / "proc"
        for d in (self.root, self.scratch, self.proc, self.root / ".services"):
            d.mkdir()
        self.bare = self.root / ".bare/r.git"
        seed = t / "seed"
        seed.mkdir()
        sh("init", "-q", "-b", "main", cwd=seed)
        (seed / "f").write_text("x")
        sh("add", "f", cwd=seed)
        sh("commit", "-qm", "init", cwd=seed)
        sh("clone", "-q", "--bare", str(seed), str(self.bare))
        sh("update-ref", "refs/remotes/origin/main", "main", cwd=self.bare)
        self.rows = []
        self.worktrees = []
        self.branches = []
        self.env = {
            **os.environ,
            "GARDENER_DIR": str(self.gdir),
            "GARDENER_ROOT": str(self.root),
            "GARDENER_TMP": str(self.scratch),
            "GARDENER_PROC": str(self.proc),
            "GARDENER_MOUNTS": str(t / "mounts"),
            "GARDENER_UNIX": str(t / "unix"),
            "GARDENER_UPTIME": "1000000",
            "CLAUDE_BARE": str(self.root / ".bare"),
            "CLAUDE_SERVICES_DIR": str(self.root / ".services"),
            "HYGIENE_FILE": str(t / "hygiene.jsonl"),
            "SCHEDULER_DIR": str(t / "sched"),
            "GARDENER_RUNS": str(self.gdir / "runs.jsonl"),
        }
        (t / "mounts").write_text("")
        (t / "unix").write_text("")
        self.hyg = t / "hygiene.jsonl"

    def worktree(self, path, branch, commit=False, **row):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        sh("worktree", "add", "-q", "-b", branch, str(path), "main", cwd=self.bare)
        if commit:
            (path / "new").write_text("n")
            sh("add", "new", cwd=path)
            sh("commit", "-qm", "new", cwd=path)
        age(path)
        self.worktrees.append(
            {
                "path": str(path),
                "branch": branch,
                "dirty": False,
                "base": "refs/remotes/origin/main",
                "ahead": 1 if commit else 0,
                "merged-by-cherry": not commit,
                **row,
            }
        )
        return path

    def branch(self, name, commit=False, **row):
        sh("branch", name, "main", cwd=self.bare)
        self.branches.append({"branch": name, "merged-by-cherry": True, **row})

    def run_g(self, *args, **env):
        self.hyg.write_text(
            json.dumps(
                {
                    "repo": "r.git",
                    "default": "main",
                    "worktrees": self.worktrees,
                    "branches_without_worktree": self.branches,
                    "branches_without_upstream": [],
                }
            )
            + "\n"
        )
        r = subprocess.run(
            [str(BIN), *args],
            env={**self.env, **env},
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def proposed(self, out, what):
        return any(what in line for line in out.splitlines() if line.startswith("- ["))

    def test_merged_clean_worktree_is_proposed_with_command(self):
        wt = self.worktree(self.root / "ws/r", "feature/ws")
        out = self.run_g()
        self.assertIn("## worktree", out)
        self.assertIn(f"git -C {self.bare} worktree remove {wt}", out)
        self.assertEqual((self.gdir / "proposals.md").read_text(), out)

    def test_dirty_worktree_not_proposed(self):
        wt = self.worktree(self.root / "ws/r", "feature/ws")
        (wt / "untracked").write_text("u")
        age(wt)
        self.assertEqual(self.run_g(), "")

    def test_dirty_flag_unknown_not_proposed(self):
        self.worktree(self.root / "ws/r", "feature/ws", dirty=None)
        self.assertEqual(self.run_g(), "")

    def test_unmerged_worktree_not_proposed(self):
        self.worktree(self.root / "ws/r", "feature/ws", commit=True)
        self.assertEqual(self.run_g(), "")

    def test_unmerged_even_if_hygiene_claims_merged(self):
        self.worktree(self.root / "ws/r", "feature/ws", commit=True, ahead=0)
        self.worktrees[-1]["merged-by-cherry"] = True
        out = self.run_g()
        self.assertEqual(out, "")

    def test_unpushed_commit_not_proposed(self):
        # Merged by patch id (a cherry-pick on main) but the branch commit is not on main.
        wt = self.worktree(self.root / "ws/r", "feature/ws", commit=True)
        sh("checkout", "-q", "--detach", "main", cwd=wt)
        main = self.root / "ws/main"
        sh("worktree", "add", "-q", str(main), "main", cwd=self.bare)
        sh("cherry-pick", "-n", "feature/ws", cwd=main)
        sh("commit", "-qm", "squashed", cwd=main)
        sh("update-ref", "refs/remotes/origin/main", "main", cwd=self.bare)
        sh("checkout", "-q", "feature/ws", cwd=wt)
        age(wt)
        self.worktrees[-1].update({"ahead": 0, "merged-by-cherry": True})
        self.assertEqual(self.run_g(), "")

    def test_recent_modification_not_proposed(self):
        wt = self.worktree(self.root / "ws/r", "feature/ws")
        (wt / "f").touch()
        self.assertEqual(self.run_g(), "")

    def test_never_touch_protected_roots(self):
        self.worktree(self.root / "_tools/r", "feature/tools")
        self.worktree(self.root / ".services/r", "feature/svc")
        self.worktree(self.root / ".bare/w", "feature/bare")
        self.assertEqual(self.run_g(), "")

    def test_policy_protect_adds_but_cannot_remove(self):
        self.worktree(self.root / "ws/r", "feature/ws")
        self.gdir.mkdir()
        (self.gdir / "thresholds.json").write_text(
            json.dumps({"protect": [str(self.root / "ws")]})
        )
        self.assertEqual(self.run_g(), "")

    def test_symlinked_worktree_not_proposed(self):
        wt = self.worktree(self.root / "ws/r", "feature/ws")
        link = self.root / "linkws"
        link.symlink_to(wt.parent)
        self.worktrees[-1]["path"] = str(link / "r")
        self.assertEqual(self.run_g(), "")

    def test_odd_name_not_proposed(self):
        self.worktree(self.root / "ws/r r", "feature/ws")
        self.assertEqual(self.run_g(), "")

    def test_default_branch_worktree_not_proposed(self):
        self.worktree(self.root / "ws/r", "master")
        self.assertEqual(self.run_g(), "")

    def test_path_in_use_by_process_not_proposed(self):
        wt = self.worktree(self.root / "ws/r", "feature/ws")
        p = self.proc / "42"
        p.mkdir()
        (p / "cwd").symlink_to(wt)
        self.assertEqual(self.run_g(), "")

    def test_mount_point_not_proposed(self):
        wt = self.worktree(self.root / "ws/r", "feature/ws")
        Path(self.env["GARDENER_MOUNTS"]).write_text(f"x {wt} fuse rw 0 0\n")
        self.assertEqual(self.run_g(), "")

    def test_keep_file_skips(self):
        wt = self.worktree(self.root / "ws/r", "feature/ws")
        self.gdir.mkdir()
        (self.gdir / "keep").write_text(f"{wt}\n")
        self.assertEqual(self.run_g(), "")

    def test_stale_hygiene_lists_nothing_from_git(self):
        self.worktree(self.root / "ws/r", "feature/ws")
        self.run_g()
        old = time.time() - 40 * 3600
        os.utime(self.hyg, (old, old))
        r = subprocess.run(
            [str(BIN)], env=self.env, capture_output=True, text=True, check=False
        )
        self.assertEqual(r.stdout.strip(), "worktrees: hygiene.jsonl stale")

    def test_missing_hygiene_is_hard_stop(self):
        r = subprocess.run(
            [str(BIN)],
            env={**self.env, "HYGIENE_FILE": str(self.root / "none")},
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(r.returncode, 1)
        self.assertIn("HygieneMissing", r.stderr)

    def test_merged_branch_proposed_trunk_and_unpushed_not(self):
        self.branch("old-merged")
        self.branch("dev")
        sh("branch", "ahead", "main", cwd=self.bare)
        main = self.root / "ws/m"
        sh("worktree", "add", "-q", str(main), "ahead", cwd=self.bare)
        (main / "x").write_text("x")
        sh("add", "x", cwd=main)
        sh("commit", "-qm", "x", cwd=main)
        sh("worktree", "remove", "--force", str(main), cwd=self.bare)
        self.branches.append({"branch": "ahead", "merged-by-cherry": True})
        out = self.run_g()
        self.assertTrue(self.proposed(out, "delete branch r.git:old-merged"))
        self.assertFalse(self.proposed(out, ":dev"))
        self.assertFalse(self.proposed(out, ":ahead"))
        self.assertIn(f"git -C {self.bare} branch -d old-merged", out)

    def test_unmerged_branch_not_proposed(self):
        sh("branch", "wip", "main", cwd=self.bare)
        self.branches.append({"branch": "wip", "merged-by-cherry": False})
        self.assertEqual(self.run_g(), "")

    def test_young_scratch_dir_not_proposed_old_one_is(self):
        young = self.scratch / "young"
        young.mkdir()
        (young / "f").write_text("x")
        old = self.scratch / "old"
        old.mkdir()
        (old / "f").write_text("x")
        age(old)
        out = self.run_g()
        self.assertTrue(self.proposed(out, f"remove dir {old}"))
        self.assertFalse(self.proposed(out, "young"))
        self.assertIn(f"rm -r {old}", out)

    def test_scratch_with_a_young_file_inside_not_proposed(self):
        d = self.scratch / "d"
        d.mkdir()
        (d / "old").write_text("x")
        age(d)
        (d / "new").write_text("y")
        self.assertEqual(self.run_g(), "")

    def test_workspace_with_worktree_is_not_scratch(self):
        self.worktree(self.root / "ws/r", "feature/ws", commit=True)
        age(self.root / "ws")
        self.assertEqual(self.run_g(), "")

    def test_empty_old_workspace_gets_rmdir(self):
        ws = self.root / "ws"
        ws.mkdir()
        age(ws)
        self.assertIn(f"rmdir {ws}", self.run_g())

    def test_dot_dirs_in_root_never_scratch(self):
        for n in (".bare", ".services"):
            age(self.root / n)
        self.assertEqual(self.run_g(), "")

    def test_stale_socket_proposed_listening_one_not(self):
        sub = self.scratch / "run"
        sub.mkdir()
        dead = sub / "dead.sock"
        live = sub / "live.sock"
        young = sub / "young.sock"
        socks = []
        for p in (dead, live, young):
            s = socket.socket(socket.AF_UNIX)
            s.bind(str(p))
            socks.append(s)
        self.addCleanup(lambda: [s.close() for s in socks])
        age(dead)
        age(live)
        Path(self.env["GARDENER_UNIX"]).write_text(f"0 0 0 0 0 0 0 {live}\n")
        out = self.run_g()
        self.assertTrue(self.proposed(out, f"remove socket {dead}"))
        self.assertFalse(self.proposed(out, "live.sock"))
        self.assertFalse(self.proposed(out, "young.sock"))

    def fake_proc(self, pid, name, ppid, start, cwd):
        p = self.proc / str(pid)
        p.mkdir()
        rest = " ".join(["S", str(ppid)] + ["0"] * 17 + [str(start)] + ["0"] * 5)
        (p / "stat").write_text(f"{pid} ({name}) {rest}\n")
        (p / "cmdline").write_bytes(f"/usr/bin/{name}\0-d\0".encode())
        (p / "cwd").symlink_to(cwd)

    def test_orphan_socat_proposed_only_when_old_and_orphaned(self):
        tck = os.sysconf("SC_CLK_TCK")
        self.fake_proc(100, "socat", 1, 10 * tck, self.scratch)
        (self.proc / "77").mkdir()
        self.fake_proc(101, "socat", 77, 10 * tck, self.scratch)
        self.fake_proc(102, "socat", 1, 999999 * tck, self.scratch)
        self.fake_proc(103, "vim", 1, 10 * tck, self.scratch)
        self.fake_proc(104, "socat", 1, 10 * tck, self.root / ".services")
        out = self.run_g()
        self.assertTrue(self.proposed(out, "kill 100 socat"))
        self.assertEqual(
            [x for x in out.splitlines() if x.startswith("- [ ] kill")].__len__(), 1
        )

    def test_notify_logs_counts_and_alarms_only_with_proposals(self):
        self.run_g("--notify")
        runs = (self.gdir / "runs.jsonl").read_text().splitlines()
        self.assertEqual(json.loads(runs[0])["findings"], 0)
        self.assertFalse((Path(self.env["SCHEDULER_DIR"]) / "events").exists())
        self.worktree(self.root / "ws/r", "feature/ws")
        self.run_g("--notify")
        row = json.loads((self.gdir / "runs.jsonl").read_text().splitlines()[1])
        self.assertEqual(row["checks"], {"worktree": 1})
        events = (Path(self.env["SCHEDULER_DIR"]) / "events").read_text()
        self.assertEqual(
            json.loads(events), {"alarm": "gardener", "msg": "gardener: 1 proposals"}
        )

    def test_skips_counted_per_rule(self):
        self.worktree(self.root / "_tools/r", "feature/t")
        self.run_g("--notify")
        row = json.loads((self.gdir / "runs.jsonl").read_text().splitlines()[0])
        self.assertEqual(row["skipped"], {"protected": 1})

    def test_previous_proposals_kept(self):
        self.worktree(self.root / "ws/r", "feature/ws")
        first = self.run_g()
        self.run_g()
        self.assertEqual((self.gdir / "proposals.prev.md").read_text(), first)

    def test_manual_run_logs_nothing(self):
        self.run_g()
        self.assertFalse((self.gdir / "runs.jsonl").exists())

    def test_source_has_no_mutating_call(self):
        src = BIN.read_text()
        for bad in (
            r"os\.(remove|unlink|rmdir|removedirs|rename|kill)\(",
            r"shutil\.",
            r"\.unlink\(",
            r"\.rmdir\(",
            r"\"(rm|rmdir|kill)\"",
        ):
            self.assertIsNone(re.search(bad, src), bad)
        calls = re.findall(r'git\("(?:-C", \w+, ")?([a-z-]+)"', src)
        for sub in calls:
            self.assertIn(sub, {"status", "cherry", "rev-list", "rev-parse"})


if __name__ == "__main__":
    unittest.main()
