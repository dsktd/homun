"""bin/claude-scrollback-edit against a fake emacsclient that records its arguments."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parents[2] / "bin/claude-scrollback-edit"


class ScrollbackEdit(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        client = self.home / ".config/niri/bin/emacsclient"
        client.parent.mkdir(parents=True)
        client.write_text('#!/bin/sh\nprintf \'%s\\n\' "$@" > "$HOME/args"\n')
        client.chmod(0o755)

    def run_tool(self, path):
        r = subprocess.run(
            [str(BIN), path],
            check=False,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            env=dict(os.environ, HOME=str(self.home)),
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        return (self.home / "args").read_text().splitlines()

    def test_opens_with_local_variables_and_eval_disabled(self):
        args = self.run_tool("/tmp/dump")
        self.assertEqual(args[:3], ["-c", "-a", "emacs --eval"])
        self.assertEqual(args[3], "--eval")
        self.assertEqual(
            args[4],
            '(let ((enable-local-variables nil) (enable-local-eval nil)) (find-file "/tmp/dump"))',
        )

    def test_escapes_backslash_and_quote_in_path(self):
        args = self.run_tool('/tmp/a"b\\c')
        self.assertIn('(find-file "/tmp/a\\"b\\\\c")', args[4])


if __name__ == "__main__":
    unittest.main()
