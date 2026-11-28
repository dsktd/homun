"""Tests of container/session-broker: the first turn every new claude needs."""

import importlib.machinery
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
loader = importlib.machinery.SourceFileLoader(
    "session_broker", str(ROOT / "container/session-broker")
)
spec = importlib.util.spec_from_loader("session_broker", loader)
broker = importlib.util.module_from_spec(spec)
loader.exec_module(broker)


class FirstTurnTest(unittest.TestCase):
    def prompt(self, **env: str) -> str:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, env):
            if not env:
                os.environ.pop("BROKER_PROMPT", None)
            return broker.Session(Path(tmp), []).prompt

    def test_default_when_unset(self) -> None:
        self.assertEqual(broker.FIRST_TURN, self.prompt())

    def test_role_prompt_wins(self) -> None:
        self.assertEqual("hello", self.prompt(BROKER_PROMPT="hello"))


if __name__ == "__main__":
    unittest.main()
