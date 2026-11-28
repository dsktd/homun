"""Shadow test of `homund msg` against the shell container/homun-msg: on every case both leave
the same inbox lines (id and ts aside), the same rotated files, stderr and exit code."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OLD = ["sh", str(ROOT / "container/homun-msg-legacy")]
HOMUND = os.environ.get("HOMUND") or str(ROOT / "core/homund/target/debug/homund")

CASES = [
    ({}, ["send", "mgr", "worker", "plain words"]),
    ({}, ["send", "mgr", "a", "y" * 900 + "\n\t"]),
    ({}, ["send", "mgr", "a", "quotes \" and \\ back\x01\x7f é ünï 😀"]),
    ({}, ["send", "mgr", 'al"ar\\m\x7f', "m"]),
    ({}, ["send", "mgr", "é" * 64, "m"]),
    ({}, ["send", "mgr", "x" * 65, "m"]),
    ({}, ["send", "mgr", "", "m"]),
    ({}, ["send", "mgr", "a", ""]),
    ({}, ["send", "mgr", "a", "-n"]),
    ({}, ["send", "mgr", "--help", "m"]),
    ({}, ["send", "mgr"]),
    ({}, ["send", "mgr", "a", "m", "extra"]),
    ({}, ["send", "../x", "a", "m"]),
    ({}, ["send", "Mgr", "a", "m"]),
    ({}, ["send"]),
    ({}, []),
    ({}, ["post", "mgr", "a", "m"]),
    ({"HOMUN_ROLE": ""}, ["send", "mgr", "a", "m"]),
    ({"HOMUN_ROLE": "", "CLAUDE_ROLE": "auditor"}, ["send", "mgr", "a", "m"]),
    ({"HOMUN_VIA": "phone"}, ["send", "mgr", "a", "m"]),
    ({"HOMUN_VIA": "Bad Via"}, ["send", "mgr", "a", "m"]),
    ({}, ["send", "rot", "a", "after rotation"]),
    ({}, ["tail", "seed"]),
    ({}, ["tail", "seed", "1"]),
    ({}, ["tail", "seed", ""]),
    ({}, ["tail", "none"]),
]


def run(cmd, env, args):
    with tempfile.TemporaryDirectory() as bus:
        b = Path(bus)
        (b / "rot").mkdir()
        (b / "rot/inbox.jsonl").write_text("x" * 1048576 + "\n")
        (b / "seed").mkdir()
        (b / "seed/inbox.jsonl").write_text("one\ntwo\nthree\n")
        full = {**os.environ, "HOMUN_BUS": bus, "HOMUN_ROLE": "writer", **env}
        full.pop("HOMUN_VIA", None) if "HOMUN_VIA" not in env else None
        p = subprocess.run(cmd + args, env=full, capture_output=True)
        files = {}
        for f in sorted(b.rglob("*.jsonl")):
            name = str(f.relative_to(b))
            name = name.split(".")[0] + (".rotated" if f.name != "inbox.jsonl" else "")
            lines = []
            for line in f.read_bytes().splitlines():
                try:
                    rec = json.loads(line)
                    rec["id"], rec["ts"] = "ID", "TS"
                    line = json.dumps(rec)
                except ValueError:
                    pass
                line = line if isinstance(line, str) else line.decode()
                lines.append(line if len(line) < 4096 else f"<{len(line)} chars>")
            files[name] = lines[-3:]
        out = [s.replace(bus.encode(), b"BUS") for s in (p.stdout, p.stderr)]
        return p.returncode, *out, files


@unittest.skipUnless(shutil.which(HOMUND) or Path(HOMUND).exists(), "no homund build")
class ShadowTest(unittest.TestCase):
    def test_cases(self):
        for env, args in CASES:
            with self.subTest(env=env, args=args):
                self.assertEqual(run(OLD, env, args), run([HOMUND, "msg"], env, args))


if __name__ == "__main__":
    unittest.main()
