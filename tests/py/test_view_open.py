import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "bin" / "claude-view-open"

PODMAN = """#!/bin/sh
# podman exec NAME claude-view size|fit ...
shift 2
case $2 in
size) [ -n "$FAKE_NOSIZE" ] && exit 1; echo "100 100" ;;
fit) echo "$@" >"$FAKE_DIR/fit"; echo "10 5" ;;
esac
"""
ZELLIJ = '#!/bin/sh\necho "$@" >"$FAKE_DIR/zellij.args"\n'
STTY = '#!/bin/sh\n[ "$1" = size ] && echo "50 200"\n'


class ViewOpenTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        for name, body in (("podman", PODMAN), ("zellij", ZELLIJ), ("stty", STTY)):
            (self.dir / name).write_text(body)
            (self.dir / name).chmod(0o755)

    def run_script(self, **extra):
        env = dict(os.environ, PATH=f"{self.dir}:{os.environ['PATH']}", FAKE_DIR=str(self.dir), CLAUDE_CONTAINER="c")
        env.update(extra)
        return subprocess.run(
            ["sh", str(SCRIPT)], check=False, capture_output=True, text=True, env=env, stdin=subprocess.DEVNULL
        )

    def test_opens_a_sized_centred_pane(self):
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.dir / "fit").read_text().split(), ["claude-view", "fit", "100", "100", "200", "50"])
        # content 10x5: width 12 with the frame, height 9 with frame and caption; centred in 200x50
        self.assertEqual(
            (self.dir / "zellij.args").read_text().split(),
            [
                "run",
                "--floating",
                "--close-on-exit",
                "--name",
                "view",
                "--width",
                "12",
                "--height",
                "9",
                "-x",
                "94",
                "-y",
                "20",
                "--",
                "claude-view-pane",
            ],
        )

    def test_falls_back_to_the_plain_pane(self):
        r = self.run_script(FAKE_NOSIZE="1")
        self.assertIn("no image size", r.stderr)
        self.assertEqual(
            (self.dir / "zellij.args").read_text().split(),
            ["run", "--floating", "--close-on-exit", "--name", "view", "--", "claude-view-pane"],
        )


if __name__ == "__main__":
    unittest.main()
