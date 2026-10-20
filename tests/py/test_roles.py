"""Tests of bin/claude-roles and that manager/ROLES.md is its generated output."""

import json
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "bin/claude-roles"
FIELDS = {
    "name",
    "status",
    "emoji",
    "colour",
    "job",
    "trigger",
    "model",
    "may",
    "never",
    "reports",
}


def run(*args):
    return subprocess.run(
        [str(TOOL), *args], check=False, capture_output=True, text=True
    )


class RolesTest(unittest.TestCase):
    def test_roles_md_matches_registry(self):
        self.assertEqual((ROOT / "manager/ROLES.md").read_text(), run("doc").stdout)

    def test_registry_is_complete_and_distinct(self):
        roles = json.loads((ROOT / "container/roles.json").read_text())
        for role in roles.values():
            self.assertEqual(set(role), FIELDS)
            self.assertEqual(len(role["colour"]), 3)
        for field in ("emoji", "name"):
            values = [r[field] for r in roles.values()]
            self.assertEqual(len(values), len(set(values)))
        colours = [tuple(r["colour"]) for r in roles.values()]
        self.assertEqual(len(colours), len(set(colours)))

    def test_show_and_unknown(self):
        self.assertIn("🔧 Mechanic", run("show", "mechanic").stdout)
        bad = run("show", "nope")
        self.assertEqual(bad.returncode, 1)
        self.assertIn("unknown role", bad.stderr)


if __name__ == "__main__":
    unittest.main()
