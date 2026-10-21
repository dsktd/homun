import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

TOOL = Path(__file__).resolve().parents[2] / "container" / "claude-view"
SERVE = TOOL.parent / "services" / "view" / "serve.py"


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

    def test_publish_sanitizes_name_and_title(self):
        r = self.run_tool("publish", self.image("a\x1b[2Jb c.png"), "--title", "T\x1b[31mx\x07")
        self.assertEqual(r.returncode, 0, r.stderr)
        (row,) = self.index()
        self.assertTrue(row["file"].endswith("-a__2Jb_c.png"), row["file"])
        self.assertEqual(row["title"], "T[31mx")

    def test_list_and_show_filter_old_index_rows(self):
        images = self.root / "images"
        images.mkdir(parents=True)
        (images / "o\x1bc.png").write_bytes(b"x")
        row = {"ts": 0, "title": "bad\x1b]0;pwn\x07", "file": "o\x1bc.png", "bytes": 1}
        (self.root / "index.jsonl").write_text(json.dumps(row) + "\n")
        # The fake chafa echoes the picture path, so only the caption line of show is ours
        for out in (self.run_tool("list").stdout, self.run_tool("show").stdout.splitlines()[-1]):
            self.assertNotIn("\x1b", out)
            self.assertNotIn("\x07", out)
            self.assertIn("bad]0;pwn", out)

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


class ServeTest(unittest.TestCase):
    def test_pages_and_images_are_nosniff(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "images").mkdir()
            (Path(tmp) / "images" / "a.png").write_bytes(b"x")
            (Path(tmp) / "index.jsonl").write_text(json.dumps({"ts": 0, "title": "t", "file": "a.png"}) + "\n")
            os.environ["CLAUDE_VIEW_DIR"] = tmp
            self.addCleanup(os.environ.pop, "CLAUDE_VIEW_DIR")
            spec = importlib.util.spec_from_file_location("view_serve", SERVE)
            serve = importlib.util.module_from_spec(spec)
            with mock.patch.object(sys, "argv", [str(SERVE)]):
                spec.loader.exec_module(serve)
            server = ThreadingHTTPServer(("127.0.0.1", 0), serve.Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            for route in ("/", "/images/a.png"):
                with urllib.request.urlopen(f"http://127.0.0.1:{server.server_port}{route}") as r:
                    self.assertEqual(r.headers["X-Content-Type-Options"], "nosniff", route)
            with self.assertRaises(urllib.error.HTTPError) as err:
                urllib.request.urlopen(f"http://127.0.0.1:{server.server_port}/missing")
            err.exception.close()
            self.assertEqual(err.exception.headers["X-Content-Type-Options"], "nosniff")


if __name__ == "__main__":
    unittest.main()
