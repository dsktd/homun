# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import os
import stat
import subprocess
import tempfile
import unittest

BIN = os.path.join(os.path.dirname(__file__), "..", "..", "bin", "claude-pane-log")

# A stand-in for util-linux script: honours -q -e -c <cmd> <file>, runs the
# command with sh and copies its output to the file, returning its status.
FAKE_SCRIPT = """#!/bin/sh
while [ $# -gt 2 ]; do
    case $1 in -c) cmd=$2; shift 2 ;; *) shift ;; esac
done
printf 'Script started on now\\n' >"$1"
sh -c "$cmd" >>"$1"
st=$?
printf 'Script done on now\\n' >>"$1"
cat "$1" | sed '1d;$d'
exit $st
"""


class PaneLogTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.logs = os.path.join(tmp.name, "logs")
        self.bin = os.path.join(tmp.name, "bin")
        os.mkdir(self.bin)
        script = os.path.join(self.bin, "script")
        with open(script, "w") as f:
            f.write(FAKE_SCRIPT)
        os.chmod(script, 0o755)
        self.env = dict(
            os.environ,
            CLAUDE_LOG_DIR=self.logs,
            PATH=self.bin + os.pathsep + os.environ["PATH"],
        )

    def run_log(self, *args):
        return subprocess.run(
            ["sh", BIN, *args],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )

    def files(self):
        return sorted(os.listdir(self.logs))

    def test_log_written_in_private_dir(self):
        r = self.run_log("demo", "echo", "it's here")
        self.assertEqual(r.returncode, 0, r.stderr)
        (name,) = self.files()
        self.assertRegex(name, r"^pane-demo-\d{8}-\d{6}\.log$")
        with open(os.path.join(self.logs, name)) as f:
            self.assertIn("it's here", f.read())
        self.assertEqual(stat.S_IMODE(os.stat(self.logs).st_mode), 0o700)

    def test_bad_name_rejected(self):
        for name in ("Bad", "a b", "a/b", "x;y", ""):
            r = self.run_log(name, "true")
            self.assertEqual(r.returncode, 2, name)
        self.assertFalse(os.path.exists(self.logs))

    def test_exit_status_kept(self):
        self.assertEqual(self.run_log("demo", "sh", "-c", "exit 7").returncode, 7)

    def test_rotation_keeps_ten_per_name(self):
        os.mkdir(self.logs)
        for i in range(12):
            for name in ("demo", "other"):
                p = os.path.join(self.logs, f"pane-{name}-20200101-0000{i:02d}.log")
                with open(p, "w"):
                    pass
                os.utime(p, (4_000_000_000 + i, 4_000_000_000 + i))
        self.run_log("demo", "true")
        names = self.files()
        self.assertEqual(sum(n.startswith("pane-demo-") for n in names), 10)
        self.assertEqual(sum(n.startswith("pane-other-") for n in names), 12)

    def test_old_logs_deleted(self):
        os.mkdir(self.logs)
        p = os.path.join(self.logs, "pane-other-20200101-000000.log")
        with open(p, "w"):
            pass
        os.utime(p, (1_000_000_000, 1_000_000_000))
        self.run_log("demo", "true")
        self.assertNotIn("pane-other-20200101-000000.log", self.files())

    def test_show_strips_escapes(self):
        os.mkdir(self.logs)
        p = os.path.join(self.logs, "pane-demo-20200101-000000.log")
        with open(p, "wb") as f:
            f.write(
                b"Script started on 2020-01-01\n"
                b"\x1b[31mred\x1b[0m\r\n"
                b"\x1b]0;title\x07plain\x1b(B\r\n"
                b"\x1b]8;;http://x\x1b\\link\r\n"
                b"Script done on 2020-01-01\n"
            )
        r = self.run_log("show", "demo")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "red\nplain\nlink\n")

    def test_show_without_log_fails(self):
        self.assertEqual(self.run_log("show", "nothing").returncode, 1)

    def test_list_newest_first(self):
        os.mkdir(self.logs)
        for i, name in enumerate(("a", "b")):
            p = os.path.join(self.logs, f"pane-{name}-20200101-000000.log")
            with open(p, "w") as f:
                f.write("x" * 5)
            os.utime(p, (1_600_000_000 + i, 1_600_000_000 + i))
        lines = self.run_log("list").stdout.splitlines()
        self.assertEqual(len(lines), 2)
        self.assertTrue(lines[0].endswith("pane-b-20200101-000000.log"))
        self.assertIn("5", lines[0])

    def test_without_script_runs_command(self):
        env = dict(self.env, PATH="/usr/bin:/bin")
        os.remove(os.path.join(self.bin, "script"))
        r = subprocess.run(
            ["/bin/sh", BIN, "demo", "echo", "hi"],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        if os.path.exists("/usr/bin/script") or os.path.exists("/bin/script"):
            self.skipTest("a real script is on the minimal PATH")
        self.assertEqual(r.stdout, "hi\n")
        self.assertIn("logging is off", r.stderr)


if __name__ == "__main__":
    unittest.main()
