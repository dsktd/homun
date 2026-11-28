"""The Schedule section of container/emacs/claude-dashboard.el, run under emacs --batch on a temp schedule.org."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

EMACS_DIR = Path(__file__).resolve().parents[2] / "container/emacs"
EMACS = shutil.which("emacs")

ORG = """#+TITLE: schedule
* later :sched:
SCHEDULED: <2099-10-18 Sun 09:00 +1d>
:PROPERTIES:
:CRON: 0 9 * * *
:END:
* soon :reset:
SCHEDULED: <2099-10-17 Sat 13:00>
* past :sched:
SCHEDULED: <2001-10-17 Sat 13:00>
"""

SHOW = """(progn (with-temp-buffer
  (claude-dashboard--schedule)
  (princ (buffer-string))))"""


@unittest.skipUnless(
    EMACS,
    "SKIPPED, NOT PASSED: no emacs on PATH (the Doom profile has none); run under "
    "a shell with an Emacs",
)
class ScheduleSectionTest(unittest.TestCase):
    def run_emacs(self, org, extra=()):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        path = tmp / "schedule.org"
        if org is not None:
            path.write_text(org)
        out = subprocess.run(
            [EMACS, "--batch", "-Q", "-L", str(EMACS_DIR)]
            + ["-l", "claude-dashboard"]
            + ["--eval", f'(setq claude-dashboard-schedule-file "{path}")']
            + list(extra)
            + ["--eval", SHOW],
            capture_output=True,
            text=True,
            timeout=60,
            check=True,
        )
        return out.stdout

    def test_lists_future_fires_soonest_first(self):
        text = self.run_emacs(ORG)
        self.assertIn("Schedule (2)", text)
        self.assertLess(text.index("soon"), text.index("later"))
        self.assertNotIn("past", text)
        self.assertRegex(text, r"in \d+d \d+h\s*\|\s*soon")

    def test_limit(self):
        text = self.run_emacs(
            ORG, ["--eval", "(setq claude-dashboard-schedule-shown 1)"]
        )
        self.assertIn("Schedule (1)", text)
        self.assertNotIn("later", text)

    def test_missing_file_has_no_section(self):
        self.assertEqual(self.run_emacs(None), "")


if __name__ == "__main__":
    unittest.main()
