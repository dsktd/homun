"""Imported first by every test module: no test can reach a live spool. HOME points at a temp
dir, so ~/claude/.services (approve, host requests, questions, asks, todos...) is a scratch copy;
the bus has its own variables (homun-msg reads HOMUN_BUS, the channel HOMUN_BUS_DIR)."""

import atexit
import os
import shutil
import tempfile

REAL_HOME = os.environ.get("HOME", "")
HOME = tempfile.mkdtemp(prefix="homun-test-home-")
os.environ.setdefault(
    "XDG_CONFIG_HOME", f"{REAL_HOME}/.config"
)  # git identity for tests that commit
os.environ["HOME"] = HOME
BUS = os.path.join(HOME, "bus")
os.makedirs(BUS)
os.environ["HOMUN_BUS"] = os.environ["HOMUN_BUS_DIR"] = BUS
atexit.register(shutil.rmtree, HOME, ignore_errors=True)
