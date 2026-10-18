"""collect.py against a throwaway repository and database."""

import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(
    0, str(Path(__file__).resolve().parents[2] / "container/services/maint")
)
import collect


class Collect(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.repo = str(self.dir / "demo.git")
        self.db = str(self.dir / "usage.sqlite")
        subprocess.run(["git", "init", "-q", "--bare", self.repo], check=True)
        work = self.dir / "work"
        git = ["git", "-C", str(work)]
        subprocess.run(["git", "init", "-q", str(work)], check=True)
        (work / "f").write_text("x")
        subprocess.run([*git, "add", "f"], check=True)
        subprocess.run(
            [*git, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "m"],
            check=True,
        )
        subprocess.run(
            [*git, "push", "-q", self.repo, "HEAD:refs/heads/main"], check=True
        )

    def rows(self):
        con = sqlite3.connect(self.db)
        con.row_factory = sqlite3.Row
        self.addCleanup(con.close)
        return con.execute("select * from maint_runs").fetchall()

    def test_records_counts_of_the_repository(self):
        collect.record(self.db, self.repo, "auto", 123, True, now=1000)
        (row,) = self.rows()
        self.assertEqual(
            (row["ts"], row["repo"], row["task"], row["duration_ms"], row["ok"]),
            (1000, "demo.git", "auto", 123, 1),
        )
        self.assertEqual(row["loose"], 3)  # commit, tree, blob
        self.assertEqual((row["refs"], row["garbage"]), (1, 0))
        self.assertGreater(row["size_kib"], 0)

    def test_second_run_appends_and_counts_a_failure(self):
        collect.record(self.db, self.repo, "auto", 1, True)
        collect.record(self.db, self.repo, "daily", 2, False)
        self.assertEqual([r["ok"] for r in self.rows()], [1, 0])

    def test_main_reports_a_git_failure(self):
        os.environ["MAINT_DB"] = self.db
        self.addCleanup(os.environ.pop, "MAINT_DB")
        self.assertEqual(collect.main([str(self.dir / "nope"), "auto", "1", "1"]), 1)

    def test_main_reports_an_unusable_database(self):
        os.environ["MAINT_DB"] = str(self.dir / "missing" / "usage.sqlite")
        self.addCleanup(os.environ.pop, "MAINT_DB")
        self.assertEqual(collect.main([self.repo, "auto", "1", "1"]), 1)


if __name__ == "__main__":
    unittest.main()
