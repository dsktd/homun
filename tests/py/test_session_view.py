"""Tests of container/session-view on a recorded stream: every event is shown, folded or kept."""

import importlib.machinery
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
loader = importlib.machinery.SourceFileLoader(
    "session_view", str(ROOT / "container/session-view")
)
spec = importlib.util.spec_from_loader("session_view", loader)
view = importlib.util.module_from_spec(spec)
loader.exec_module(view)
FIXTURE = ROOT / "tests/fixtures/stream/events.jsonl"


class Lines:
    def __init__(self, path: Path) -> None:
        self.path = path

    def lines(self):
        yield from self.path.read_bytes().splitlines(keepends=True)


class SessionViewTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        self.out = io.StringIO()
        self.screen = view.Screen(
            self.out, view.Unhandled(self.dir / "unhandled.jsonl")
        )
        view.follow(Lines(FIXTURE), self.screen)
        self.text = self.out.getvalue()

    def test_shows_the_useful_events(self) -> None:
        for want in (
            "session claude-test · /work",
            "∴ Pondering widgets.",
            "Looking now.",
            "⚙ Task  Probe",
            "⇢ researcher: Probe",
            "⇠ Probe completed · 512 tok",
            "denied Bash: [Destructive]",
            "✗ failed",
            "rate limit five_hour: allowed_warning",
            "done · $0.0123 · 2.5 s · 40 out · 5h 83% 7d 40%",
            "fresh session (role-recycle)",
            "session process exited (0)",
            "title Tester",
        ):
            self.assertIn(want, self.text)
        self.assertNotIn("subagent words", self.text)

    def test_keeps_the_unknown(self) -> None:
        kept = [
            json.loads(x)
            for x in (self.dir / "unhandled.jsonl").read_text().splitlines()
        ]
        self.assertEqual(["system", "unparsed"], [k["type"] for k in kept])
        self.assertEqual("brand_new_thing", kept[0]["subtype"])
        self.assertEqual(2, self.screen.unhandled.count)
        self.assertIn("unhandled system/brand_new_thing (1 this view", self.text)

    def test_log_is_capped(self) -> None:
        log = view.Unhandled(self.dir / "u.jsonl")
        log.CAP = 100
        for _ in range(5):
            log.keep({"type": "x", "pad": "y" * 80})
        self.assertTrue((self.dir / "u.jsonl.1").exists())
        self.assertLess((self.dir / "u.jsonl").stat().st_size, 400)


if __name__ == "__main__":
    unittest.main()
