"""Tests of container/claude-task-links against a fixture todos file and agent transcript."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import importlib.machinery
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "container/claude-task-links"
loader = importlib.machinery.SourceFileLoader("task_links", str(SCRIPT))
spec = importlib.util.spec_from_loader("task_links", loader)
links = importlib.util.module_from_spec(spec)
loader.exec_module(links)

TODOS = """#+title: Session todos

* Mine
** TODO Fix the board fold :ui:
some note of the user's
** TODO With an id
:PROPERTIES:
:ID: t-42
:END:

* Later
** Read the paper
"""

TRANSCRIPT = [
    {
        "type": "user",
        "message": {
            "content": [
                {
                    "type": "tool_result",
                    "content": "[main 1a2b3c4] Fold the row\n 1 file",
                }
            ]
        },
    },
    {
        "type": "assistant",
        "message": {
            "content": [{"type": "text", "text": "Folded the row.\nDetails follow."}]
        },
    },
]


class TaskLinksTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.todos = self.dir / "s.org"
        self.todos.write_text(TODOS)
        self.transcript = self.dir / "agent.jsonl"
        self.transcript.write_text("".join(json.dumps(e) + "\n" for e in TRANSCRIPT))

    def apply(self, *events):
        store = links.Links(self.dir / "links.jsonl")
        lines = [json.dumps({"todos": str(self.todos), **event}) for event in events]
        return store.apply(lines), store

    def test_slug_links_existing_heading_and_ends_it(self):
        self.apply(
            {
                "event": "start",
                "agent": "a1",
                "desc": "Fold",
                "task": "fix-the-board-fold",
                "at": 1,
            }
        )
        text = self.todos.read_text()
        self.assertIn(
            "** STRT Fix the board fold :ui:\n:PROPERTIES:\n:AGENT: [[homun-agent:a1]]\n:END:\nsome note",
            text,
        )
        changed, store = self.apply(
            {
                "event": "end",
                "agent": "a1",
                "status": "done",
                "at": 9,
                "transcript": str(self.transcript),
            }
        )
        self.assertEqual(changed, 1)
        row = store.row("a1")
        self.assertEqual(
            (row["status"], row["end"], row["commits"]), ("done", 9, ["1a2b3c4"])
        )
        self.assertIn(
            "** DONE Fix the board fold :ui:\n:PROPERTIES:\n:AGENT: [[homun-agent:a1]]\n:END:\n"
            "- done, agent a1: Folded the row. Details follow. (commits 1a2b3c4)\nsome note",
            self.todos.read_text(),
        )

    def test_id_property_and_second_agent_keeps_it_started(self):
        self.apply(
            {"event": "start", "agent": "a1", "task": "t-42"},
            {"event": "start", "agent": "a2", "task": "t-42"},
            {"event": "end", "agent": "a1", "status": "failed", "summary": "broke"},
        )
        text = self.todos.read_text()
        self.assertIn(
            "** STRT With an id\n:PROPERTIES:\n:ID: t-42\n:AGENT: [[homun-agent:a1]] [[homun-agent:a2]]\n:END:\n- failed, agent a1: broke",
            text,
        )

    def test_no_task_creates_a_heading_once(self):
        event = {"event": "start", "agent": "a9", "desc": "Sweep the logs"}
        self.assertEqual(self.apply(event, event)[0], 1)
        self.assertEqual(self.apply(event)[0], 0)
        text = self.todos.read_text()
        self.assertEqual(
            text.count(
                "** STRT Sweep the logs\n:PROPERTIES:\n:ID: agent-a9\n:AGENT: [[homun-agent:a9]]\n:END:"
            ),
            1,
        )
        self.assertTrue(text.startswith(TODOS.rstrip("\n")))
        _, store = self.apply({"event": "end", "agent": "a9", "status": "stopped"})
        self.assertIn("** FAILED Sweep the logs", self.todos.read_text())
        self.assertEqual(store.row("a9")["task"], "agent-a9")

    def test_tracker_id_touches_no_file(self):
        _, store = self.apply(
            {"event": "start", "agent": "a3", "task": "217"},
            {"event": "end", "agent": "zz"},
        )
        self.assertEqual(store.row("a3")["kind"], "tracker")
        self.assertEqual(self.todos.read_text(), TODOS)


if __name__ == "__main__":
    unittest.main()
