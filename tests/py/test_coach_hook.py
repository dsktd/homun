# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HOOK = Path(__file__).resolve().parents[2] / "container" / "coach-hook"

GOOD = (
    "Fix the thing in ~/claude/_tools/homun. Grep git log first for existing work. "
    "Read AGENTS.md and the skill. Read the lease first; wait if held, never overwrite. "
    "Commit atomically, no Claude trailers."
)


class CoachHook(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)

    def run_hook(self, mode, payload):
        r = subprocess.run(
            ["python3", "-I", str(HOOK), mode],
            input=json.dumps(payload),
            text=True,
            env=dict(os.environ, COACH_DIR=str(self.root)),
            capture_output=True,
            check=False,
        )
        self.assertEqual(r.returncode, 0)
        return r.stdout

    def rows(self):
        path = self.root / "agents.jsonl"
        return [json.loads(x) for x in path.read_text().splitlines()]

    def brief(self, prompt, tool="Agent", tuid="t1"):
        return self.run_hook(
            "brief",
            {
                "session_id": "s1",
                "tool_name": tool,
                "tool_use_id": tuid,
                "tool_input": {
                    "description": "fix",
                    "prompt": prompt,
                    "model": "sonnet",
                },
            },
        )

    def test_good_brief_is_silent_and_logged(self):
        self.assertEqual(self.brief(GOOD), "")
        row = self.rows()[0]
        self.assertEqual((row["kind"], row["lacks"]), ("spawn", []))

    def test_gaps_noted_never_denied(self):
        out = json.loads(self.brief("Commit a fix in ~/claude/_tools/homun."))
        spec = out["hookSpecificOutput"]
        self.assertNotIn("permissionDecision", spec)
        self.assertTrue(spec["additionalContext"].startswith("coach: brief lacks"))
        self.assertEqual(
            self.rows()[0]["lacks"], ["existing_work", "lease", "docs", "trailers"]
        )

    def test_lease_needs_wait_rule(self):
        self.brief(GOOD.replace("wait if held, ", ""))
        self.assertEqual(self.rows()[0]["lacks"], ["lease"])

    def test_homun_land_keeps_the_lease_rule(self):
        brief = GOOD.replace(
            "Read the lease first; wait if held, never overwrite. ", ""
        )
        self.brief(brief)
        self.assertEqual(self.rows()[0]["lacks"], ["lease"])
        self.brief(brief + " Land with homun-land feature/x.", tuid="t2")
        self.assertEqual(self.rows()[1]["lacks"], [])

    def test_emacs_brief_needs_the_mcp_rule(self):
        self.brief(GOOD + " Fix a view in claude-board.el.")
        self.assertEqual(self.rows()[0]["lacks"], ["emacs"])
        self.brief(GOOD + " Fix claude-board.el; use the emacs MCP tools.", tuid="t2")
        self.assertEqual(self.rows()[1]["lacks"], [])

    def test_plain_question_has_no_rules(self):
        self.assertEqual(self.brief("What is the capital of France?"), "")
        self.assertEqual(self.rows()[0]["lacks"], [])

    def test_other_tools_ignored(self):
        self.brief("x", tool="Bash")
        self.assertFalse((self.root / "agents.jsonl").exists())

    def test_bad_input_exits_quietly(self):
        r = subprocess.run(
            ["python3", "-I", str(HOOK), "brief"],
            input="not json",
            text=True,
            env=dict(os.environ, COACH_DIR=str(self.root)),
            capture_output=True,
            check=False,
        )
        self.assertEqual((r.returncode, r.stdout), (0, ""))

    def transcript(self, report):
        path = self.root / "agent.jsonl"
        lines = [
            {
                "type": "user",
                "timestamp": "2026-11-24T10:00:00Z",
                "message": {"role": "user", "content": GOOD},
            },
            {
                "type": "assistant",
                "timestamp": "2026-11-24T10:01:00Z",
                "message": {
                    "id": "m1",
                    "model": "claude-sonnet-5-5",
                    "content": [{"type": "text", "text": "working"}],
                    "usage": {"input_tokens": 3, "output_tokens": 10},
                },
            },
            {
                "type": "assistant",
                "timestamp": "2026-11-24T10:05:00Z",
                "message": {
                    "id": "m2",
                    "model": "claude-sonnet-5-5",
                    "content": [
                        {
                            "type": "tool_use",
                            "name": "SubagentHandback",
                            "input": {"message": report},
                        }
                    ],
                    "usage": {"input_tokens": 2, "output_tokens": 5},
                },
            },
        ]
        path.write_text("".join(json.dumps(x) + "\n" for x in lines))
        return str(path)

    def test_run_joins_spawn_and_grades(self):
        self.brief(GOOD)
        report = "Already done on main.\nChecked with the tests.\nThe UI is untested."
        self.run_hook(
            "run",
            {
                "session_id": "s1",
                "agent_id": "a1",
                "agent_type": "nest-dev",
                "agent_transcript_path": self.transcript(report),
            },
        )
        run = self.rows()[-1]
        self.assertEqual(run["description"], "fix")
        self.assertEqual(run["model"], "claude-sonnet-5-5")
        self.assertEqual(run["duration_s"], 300)
        self.assertEqual(run["tokens"]["output"], 15)
        self.assertTrue(run["already_done"])
        self.assertFalse(run["rework"])
        self.assertEqual((run["verified"], run["unverified"]), (1, 1))

    def test_double_fired_brief_logs_one_spawn(self):
        self.brief(GOOD)
        self.brief(GOOD)
        self.assertEqual([r["kind"] for r in self.rows()], ["spawn"])

    def test_run_found_by_agent_id_and_linked_by_meta(self):
        self.brief("Commit a fix in ~/claude/_tools/homun.")
        sub = self.root / "s1" / "subagents"
        sub.mkdir(parents=True)
        src = Path(self.transcript("Verified by running it."))
        (sub / "agent-a9.jsonl").write_text(src.read_text())
        (sub / "agent-a9.meta.json").write_text(
            json.dumps({"agentType": "nest-dev", "toolUseId": "t1", "model": "sonnet"})
        )
        self.run_hook(
            "run",
            {
                "session_id": "s1",
                "agent_id": "a9",
                "transcript_path": str(self.root / "s1.jsonl"),
            },
        )
        run = self.rows()[-1]
        self.assertEqual((run["tool_use_id"], run["description"]), ("t1", "fix"))
        self.assertEqual(run["duration_s"], 300)
        self.assertEqual(run["verified"], 1)
        self.assertEqual(run["brief_lacks"][0], "existing_work")


if __name__ == "__main__":
    unittest.main()
