"""Tests of bin/claude-roles and that manager/ROLES.md is its generated output."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import json
import os
import subprocess
import tomllib
import tempfile
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
        [str(TOOL), *args],
        check=False,
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "IDENTITIES_DIR": "/nonexistent",
            # the checked-in registry, never the live merged one
            "ROLES_FILE": str(ROOT / "container/roles.json"),
        },
    )


class RolesTest(unittest.TestCase):
    def test_roles_md_matches_registry(self):
        self.assertEqual((ROOT / "manager/ROLES.md").read_text(), run("doc").stdout)

    def test_registry_is_built_from_the_manifests(self):
        self.assertEqual(run("build", "check").returncode, 0)
        keys = set(tomllib.loads((ROOT / "roles/roles.toml").read_text()))
        self.assertEqual(
            keys, set(json.loads((ROOT / "container/roles.json").read_text()))
        )

    def test_build_drops_a_retired_role_from_the_systems_registry(self):
        with tempfile.TemporaryDirectory() as d:
            reg = Path(d, "registry")
            (reg / "role/gone").mkdir(parents=True)
            (reg / "role/auditor").mkdir(parents=True)
            subprocess.run(
                [str(TOOL), "build"],
                check=True,
                env={
                    **os.environ,
                    "ROLES_FILE": str(Path(d, "roles.json")),
                    "REGISTRY_DIR": str(reg),
                },
            )
            self.assertEqual([p.name for p in (reg / "role").iterdir()], ["auditor"])

    def test_registry_is_complete_and_distinct(self):
        roles = json.loads((ROOT / "container/roles.json").read_text())
        for role in roles.values():
            # what a list shows, plus how the launcher starts the role where it says so
            self.assertEqual(set(role) - {"seat", "session", "access", "wake"}, FIELDS)
            self.assertEqual(len(role["colour"]), 3)
        for field in ("emoji", "name"):
            values = [r[field] for r in roles.values()]
            self.assertEqual(len(values), len(set(values)))
        colours = [tuple(r["colour"]) for r in roles.values()]
        self.assertEqual(len(colours), len(set(colours)))

    def test_mechanic_notifies_instead_of_restarting(self):
        mechanic = json.loads((ROOT / "container/roles.json").read_text())["mechanic"]
        self.assertIn("restart or ask to restart the Manager", mechanic["never"])
        self.assertIn("notify-send", mechanic["may"])
        self.assertNotIn("request", mechanic["may"])
        guide = (ROOT / "container/mechanic/CLAUDE.md").read_text()
        self.assertIn("notify-send -a Mechanic", guide)
        self.assertNotIn("claude-mechanic-request restart", guide)

    def test_show_and_unknown(self):
        self.assertIn("🛠️ Mechanic", run("show", "mechanic").stdout)
        bad = run("show", "nope")
        self.assertEqual(bad.returncode, 1)
        self.assertIn("unknown role", bad.stderr)


if __name__ == "__main__":
    unittest.main()
