"""Tests of container/services/stage/fetch.py with a stubbed `gh`."""

import isolate  # noqa: F401, I001
import importlib.util
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

SRC = Path(__file__).resolve().parents[2] / "container/services/stage/fetch.py"
spec = importlib.util.spec_from_file_location("stage_fetch", SRC)
fetch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetch)

OK = mock.Mock(returncode=0, stdout="[]", stderr="")
BAD = mock.Mock(returncode=4, stdout="", stderr="auth")


class FetchTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        (self.root / "repos").write_text("# comment\no/r\n")
        self.cache = self.root / "prs-o-r.json"

    def test_fetch_then_wait_then_request(self):
        with mock.patch("subprocess.run", return_value=OK):
            self.assertEqual(fetch.once(self.root), ["o/r"])
            self.assertEqual(self.cache.read_text(), "[]")
            self.assertEqual(fetch.once(self.root), [])
            time.sleep(0.05)
            (self.root / "request").touch()
            self.assertEqual(fetch.once(self.root), ["o/r"])

    def test_failure_keeps_cache_and_backs_off(self):
        with mock.patch("subprocess.run", return_value=OK):
            fetch.once(self.root)
        time.sleep(0.05)
        (self.root / "request").touch()
        with mock.patch("subprocess.run", return_value=BAD) as run:
            self.assertEqual(fetch.once(self.root), [])
            self.assertEqual(fetch.once(self.root), [])
        self.assertEqual(run.call_count, 1)
        self.assertEqual(self.cache.read_text(), "[]")


if __name__ == "__main__":
    unittest.main()
