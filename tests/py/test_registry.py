"""bin/claude-registry: validation, listing, doc and graph against a temp registry."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parents[2] / "bin/claude-registry"


def info(kind, name, drop=(), **extra):
    keys = {
        "kind": kind,
        "name": name,
        "owner": "manager",
        "purpose": "p",
        "produces": "x",
        "how": "none yet",
        **extra,
    }
    lines = []
    for key, value in keys.items():
        if key not in drop:
            for v in value if isinstance(value, list) else [value]:
                lines.append(f"{key}: {v}")
    return "# a comment\n\n" + "\n".join(lines) + "\n"


class Registry(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        # MAINT_DB names no file: check then skips the comparison with the real systems
        self.env = {
            **os.environ,
            "REGISTRY_DIR": str(self.dir),
            "MAINT_DB": str(self.dir / "no.sqlite"),
        }

    def put(self, kind, name, text=None, **kw):
        d = self.dir / kind / name
        d.mkdir(parents=True)
        (d / "info").write_text(text if text is not None else info(kind, name, **kw))

    def run_r(self, *args):
        return subprocess.run(
            [str(BIN), *args], env=self.env, capture_output=True, text=True, check=False
        )

    def test_check_green(self):
        self.put("service", "a")
        (self.dir / "service/a/notes.md").write_text("free notes")
        r = self.run_r("check")
        self.assertEqual((r.returncode, r.stdout), (0, "registry: ok (1 entries)\n"))

    def test_check_names_each_problem(self):
        self.put("service", "b", info("service", "a"))
        self.put("widget", "c")
        self.put("log", "d", drop=("how",))
        self.put("role", "e", info("role", "e", purpose=""))
        (self.dir / "log" / "f").mkdir()
        out = self.run_r("check").stdout.splitlines()
        self.assertEqual(len(out), 5)
        self.assertTrue(out[1].startswith("log/f: cannot read info"))
        del out[1]
        self.assertEqual(
            out,
            [
                "log/d: missing keys how",
                "role/e: missing keys purpose",
                "service/b: should be service/a",
                "widget/c: unknown kind 'widget'",
            ],
        )

    def test_missing_directory(self):
        self.env["REGISTRY_DIR"] = str(self.dir / "nope")
        r = self.run_r("check")
        self.assertEqual(r.returncode, 1)
        self.assertIn("no such directory", r.stderr)

    def test_list_and_kind_filter(self):
        self.put("service", "a")
        self.put("table", "t")
        self.assertEqual(len(self.run_r("list").stdout.splitlines()), 2)
        out = self.run_r("list", "--kind", "table").stdout
        self.assertEqual(out, "table/t\tmanager\tp\n")

    def test_show_keeps_repeated_keys(self):
        self.put("service", "a", checked_by=["mechanic", "auditor"])
        out = self.run_r("show", "service/a").stdout.splitlines()
        self.assertIn("checked_by: mechanic", out)
        self.assertIn("checked_by: auditor", out)
        self.assertEqual(self.run_r("show", "service/zz").returncode, 1)

    def test_bad_usage(self):
        self.assertEqual(self.run_r("list", "--kind").returncode, 2)
        self.assertEqual(self.run_r().returncode, 2)

    def test_doc_is_one_table_per_kind(self):
        self.put("service", "a", checked_by=["mechanic", "auditor"], port="8421")
        self.put("table", "t", purpose="a|b")
        out = self.run_r("doc").stdout
        self.assertEqual(out.count("## "), 2)
        self.assertIn(
            "| a | manager | p | x | mechanic, auditor | none yet | port: 8421 |", out
        )
        self.assertIn("a\\|b", out)
        self.assertEqual(out, self.run_r("doc").stdout)

    def test_graph_edges(self):
        self.put("role", "mechanic")
        self.put("role", "manager")
        self.put("service", "s", checked_by=["mechanic", "claude-x"])
        self.put("schedule", "mechanic", owner="mechanic")
        out = self.run_r("graph").stdout.splitlines()
        self.assertEqual(out[0], "flowchart LR")
        self.assertIn("  role_manager --> service_s", out)
        self.assertIn("  service_s -.-> role_mechanic", out)
        self.assertIn("  service_s -.-> script_claude_x", out)
        self.assertIn("  schedule_mechanic --> role_mechanic", out)


if __name__ == "__main__":
    unittest.main()
