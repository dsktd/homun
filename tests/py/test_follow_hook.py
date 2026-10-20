import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HOOK = Path(__file__).resolve().parents[2] / "container" / "follow-hook.sh"


class FollowHook(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.dir = self.root / "follow"
        self.repo = self.root / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)

    def run_hook(self, payload):
        env = dict(os.environ, CLAUDE_FOLLOW_DIR=str(self.dir))
        r = subprocess.run(
            ["sh", str(HOOK)],
            input=payload,
            text=True,
            env=env,
            capture_output=True,
            check=False,
        )
        self.assertEqual(r.returncode, 0)

    def lines(self, sid="s1"):
        path = self.dir / f"{sid}.jsonl"
        return [json.loads(x) for x in path.read_text().splitlines()]

    def edit(self, **extra):
        return json.dumps(
            {
                "session_id": "s1",
                "hook_event_name": "PostToolUse",
                "tool_name": "Edit",
                "cwd": str(self.repo),
                "tool_input": {
                    "file_path": str(self.repo / "a.txt"),
                    "new_string": "SECRET",
                },
                **extra,
            }
        )

    def test_main_edit(self):
        self.run_hook(self.edit())
        (row,) = self.lines()
        self.assertEqual(row["agent"], "main")
        self.assertEqual(row["tool"], "Edit")
        self.assertEqual(row["file"], str(self.repo / "a.txt"))
        self.assertEqual(row["worktree"], str(self.repo.resolve()))
        self.assertNotIn("SECRET", (self.dir / "s1.jsonl").read_text())

    def test_subagent_and_notebook(self):
        self.run_hook(self.edit(agent_id="ag1", agent_type="Explore"))
        self.run_hook(
            json.dumps(
                {
                    "session_id": "s1",
                    "tool_name": "NotebookEdit",
                    "cwd": str(self.repo),
                    "tool_input": {"notebook_path": "n.ipynb"},
                }
            )
        )
        a, b = self.lines()
        self.assertEqual(a["agent"], "ag1")
        self.assertEqual(a["agent_type"], "Explore")
        self.assertEqual(b["file"], str(self.repo / "n.ipynb"))

    def test_session_end_deletes(self):
        self.run_hook(self.edit())
        self.run_hook(json.dumps({"session_id": "s1", "hook_event_name": "SessionEnd"}))
        self.assertFalse((self.dir / "s1.jsonl").exists())

    def test_bad_input_is_harmless(self):
        self.run_hook("not json")
        self.run_hook(
            json.dumps({"session_id": "../x", "tool_input": {"file_path": "/a"}})
        )
        self.assertFalse(self.dir.exists())


if __name__ == "__main__":
    unittest.main()
