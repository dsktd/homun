"""Tests of container/statusline.sh: contextual segments and the width budget, fed sample JSON on stdin."""

import json
import os
import re
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "container/statusline.sh"
REGISTRY = SCRIPT.parent / "roles.json"
ANSI = re.compile(r"\x1b\[[0-9;]*m")


class StatuslineTest(unittest.TestCase):
    def render(
        self,
        five=20,
        seven=30,
        questions=0,
        width=None,
        session="s",
        pinned="s",
        name=None,
        roles=True,
        raw=False,
    ):
        now = int(time.time())
        data = {
            "session_id": session,
            "model": {"display_name": "Opus"},
            "context_window": {"remaining_percentage": 60},
            "cost": {"total_cost_usd": 4.2},
            "rate_limits": {
                "five_hour": {"used_percentage": five, "resets_at": now + 5000},
                "seven_day": {"used_percentage": seven, "resets_at": now + 200000},
            },
        }
        if name:
            data["session_name"] = name
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "pending").mkdir()
            for i in range(questions):
                (tmp / "pending" / f"{i}.json").write_text("{}")
            (tmp / "pinned").write_text(pinned)
            env = {
                "PATH": os.environ["PATH"],
                "HOME": str(tmp),
                "CLAUDE_STATUS_STATE": str(tmp / "state"),
                "CLAUDE_QUESTIONS_DIR": str(tmp),
                "USAGE_MODE_FILE": str(tmp / "none"),
                "MANAGER_SESSION_FILE": str(tmp / "pinned"),
                "ROLES_FILE": str(tmp / "roles.json"),
            }
            if roles is True:
                roles = REGISTRY.read_text()
            if roles:
                (tmp / "roles.json").write_text(roles)
            if width:
                env["COLUMNS"] = str(width)
            out = subprocess.run(
                ["sh", str(SCRIPT)],
                input=json.dumps(data),
                env=env,
                capture_output=True,
                text=True,
                check=True,
            ).stdout
        return out if raw else ANSI.sub("", out).strip()

    def test_low_usage_hides_budgets(self):
        line = self.render()
        self.assertEqual(line, "🧮 Tally  Opus ctx40% $4.2")

    def test_high_usage_shows_budgets_and_reset(self):
        line = self.render(five=80, seven=60)
        self.assertIn("80%/5h 60%/wk ↻1h", line)

    def test_reset_hidden_when_5h_moderate(self):
        line = self.render(five=60, seven=10)
        self.assertIn("60%/5h 10%/wk", line)
        self.assertNotIn("↻", line)

    def test_questions_kept_when_narrow(self):
        line = self.render(five=80, questions=2, width=18)
        self.assertEqual(line, "🧮 Tally  Opus ❓2")

    def test_other_session_has_no_manager_segments(self):
        line = self.render(questions=2, session="x", pinned="s")
        self.assertNotIn("❓", line)
        self.assertIn("🤖 agent", line)

    def test_role_session_wears_role_plate(self):
        line = self.render(session="x", pinned="s", name="Mechanic")
        self.assertTrue(line.startswith("🔧 Mechanic  Opus"))
        raw = self.render(session="x", pinned="s", name="mechanic", raw=True)
        self.assertIn("48;2;240;140;70m", raw)

    def test_role_prefixed_name(self):
        for name in ("auditor-pr12", "auditor:pr12"):
            line = self.render(session="x", pinned="s", name=name)
            self.assertTrue(line.startswith("🔍 Auditor "), line)

    def test_unknown_name_keeps_blue_plate(self):
        for name in ("mechanical", "other"):
            raw = self.render(session="x", pinned="s", name=name, raw=True)
            self.assertIn("48;2;60;90;200m", raw)
            self.assertIn("🤖 " + name, raw)

    def test_missing_or_invalid_registry_falls_back(self):
        for roles in (False, "not json", "[1]", '{"mechanic": 3}'):
            line = self.render(session="x", pinned="s", name="mechanic", roles=roles)
            self.assertTrue(line.startswith("🤖 mechanic "), line)

    def test_pinned_session_stays_tally(self):
        line = self.render(session="s", pinned="s", name="mechanic")
        self.assertTrue(line.startswith("🧮 Tally"))


if __name__ == "__main__":
    unittest.main()
