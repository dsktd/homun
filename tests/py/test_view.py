import importlib.machinery
import importlib.util
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parents[2] / "container" / "claude-view"

_loader = importlib.machinery.SourceFileLoader("claude_view", str(TOOL))
_spec = importlib.util.spec_from_loader("claude_view", _loader)
view = importlib.util.module_from_spec(_spec)
_loader.exec_module(view)


def png(w, h):
    return b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", w, h)


def gif(w, h):
    return b"GIF89a" + struct.pack("<HH", w, h)


def jpeg(w, h):
    app = b"\xff\xe0" + struct.pack(">H", 4) + b"\0\0"
    sof = b"\xff\xc0" + struct.pack(">HBHH", 11, 8, h, w)
    return b"\xff\xd8" + app + sof


def webp(kind, w, h):
    if kind == b"VP8 ":
        body = b"\0" * 3 + b"\x9d\x01\x2a" + struct.pack("<HH", w, h)
    elif kind == b"VP8L":
        body = b"\x2f" + struct.pack("<I", (w - 1) | ((h - 1) << 14))
    else:
        body = b"\0" * 4 + (w - 1).to_bytes(3, "little") + (h - 1).to_bytes(3, "little")
    return b"RIFF" + struct.pack("<I", 4 + 8 + len(body)) + b"WEBP" + kind + struct.pack("<I", len(body)) + body


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

    def test_image_size_per_format(self):
        cases = {
            "a.png": png(300, 200),
            "a.gif": gif(300, 200),
            "a.jpg": jpeg(300, 200),
            "v.webp": webp(b"VP8 ", 300, 200),
            "l.webp": webp(b"VP8L", 300, 200),
            "x.webp": webp(b"VP8X", 300, 200),
        }
        for name, data in cases.items():
            path = self.tmpdir / name
            path.write_bytes(data)
            self.assertEqual(view.image_size(path), (300, 200), name)

    def test_image_size_errors(self):
        for data, msg in ((b"hello world", "unknown image format"), (png(1, 1)[:12], "truncated image header")):
            path = self.tmpdir / "bad"
            path.write_bytes(data)
            with self.assertRaisesRegex(view.ViewError, msg):
                view.image_size(path)

    def test_fit_table(self):
        cases = [
            # img_w, img_h, cols, rows, cell_px, expected
            (1000, 500, 200, 50, None, (160, 40)),  # wide: the box is 160x40
            (500, 1000, 200, 50, None, (40, 40)),  # tall: limited by rows
            (1000, 1000, 100, 100, None, (80, 40)),  # square at 1:2 cells
            (100, 100, 200, 50, (10, 20), (10, 5)),  # small: natural size in cells
            (4000, 2000, 200, 50, (10, 20), (160, 40)),  # large with known cells: the box
            (1, 1, 10, 10, None, (8, 4)),  # tiny image, no cell size: scaled up to the box
        ]
        for w, h, c, r, px, want in cases:
            self.assertEqual(view.fit(w, h, c, r, cell_px=px), want, (w, h, c, r, px))

    def test_size_and_fit_subcommands(self):
        path = self.tmpdir / "a.png"
        path.write_bytes(png(300, 200))
        self.run_tool("publish", str(path))
        r = self.run_tool("size")
        self.assertEqual((r.returncode, r.stdout), (0, "300 200\n"), r.stderr)
        self.assertEqual(self.run_tool("fit", "100", "100", "200", "50", "10", "20").stdout, "10 5\n")
        self.assertIn("fit takes", self.run_tool("fit", "1", "2").stderr)
        self.assertIn(
            "no images published yet",
            self.run_tool("size", env=dict(self.env, CLAUDE_VIEW_DIR=str(self.tmpdir / "none"))).stderr,
        )


if __name__ == "__main__":
    unittest.main()
