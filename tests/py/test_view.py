import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parents[2] / "container" / "claude-view"


class ViewTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.tmpdir = Path(self.tmp.name)
        self.root = self.tmpdir / "view"
        fake = self.tmpdir / "chafa"
        fake.write_text('#!/bin/sh\necho "drawn $*"\n')
        fake.chmod(0o755)
        self.env = dict(os.environ, CLAUDE_VIEW_DIR=str(self.root), CLAUDE_VIEW_CHAFA=str(fake))

    def run_tool(self, *args, env=None):
        return subprocess.run(
            [sys.executable, str(TOOL), *args],
            check=False,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            env=env or self.env,
        )

    def image(self, name="a.png"):
        path = self.tmpdir / name
        path.write_bytes(b"x")
        return str(path)

    def index(self):
        return [json.loads(line) for line in (self.root / "index.jsonl").read_text().splitlines()]

    def test_publish_copies_and_indexes(self):
        r = self.run_tool("publish", self.image(), "--title", "T")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("press C-SPC I", r.stdout)
        (row,) = self.index()
        self.assertEqual((row["title"], row["bytes"]), ("T", 1))
        self.assertTrue(row["file"].endswith("-a.png"))
        self.assertTrue((self.root / "images" / row["file"]).exists())

    def test_publish_rejects_other_types_and_missing_files(self):
        r = self.run_tool("publish", self.image("a.txt"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("unsupported type '.txt'", r.stderr)
        r = self.run_tool("publish", str(self.tmpdir / "none.png"))
        self.assertIn("no such file", r.stderr)
        self.assertFalse((self.root / "index.jsonl").exists())

    def test_publish_prunes_to_newest_200(self):
        images = self.root / "images"
        images.mkdir(parents=True)
        rows = []
        for i in range(205):
            name = f"20200101-{i:06d}-o.png"
            (images / name).write_bytes(b"x")
            rows.append({"ts": i, "title": "", "file": name, "bytes": 1})
        (self.root / "index.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
        self.assertEqual(self.run_tool("publish", self.image()).returncode, 0)
        self.assertEqual(len(self.index()), 200)
        self.assertEqual(len(list(images.iterdir())), 200)
        self.assertFalse((images / "20200101-000000-o.png").exists())

    def test_list_newest_first(self):
        self.run_tool("publish", self.image("a.png"), "--title", "first")
        self.run_tool("publish", self.image("b.png"), "--title", "second")
        out = self.run_tool("list").stdout.splitlines()
        self.assertEqual(len(out), 2)
        self.assertTrue(out[0].lstrip().startswith("1") and out[0].endswith("second"))
        self.assertTrue(out[1].lstrip().startswith("2") and out[1].endswith("first"))

    def test_show_draws_once_without_a_tty(self):
        self.run_tool("publish", self.image())
        r = self.run_tool("show")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("drawn -f kitty", r.stdout)
        self.assertIn("-a.png", r.stdout)

    def test_show_errors(self):
        self.assertIn("no images published yet", self.run_tool("show").stderr)
        self.run_tool("publish", self.image())
        self.assertIn("use latest or 1-1", self.run_tool("show", "3").stderr)
        env = dict(self.env, CLAUDE_VIEW_CHAFA=str(self.tmpdir / "missing"))
        self.assertIn("chafa not found", self.run_tool("show", env=env).stderr)


if __name__ == "__main__":
    unittest.main()
