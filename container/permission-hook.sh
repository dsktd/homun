#!/usr/bin/env python3
''''exec python3 "$0" "$@" # sh runs this line; Python sees a string ''' 
"""Shim over `homund approve`, the PermissionRequest hook: runs it when the installed homund has that
subcommand, else the sh implementation (permission-hook-legacy.sh), kept for one release.
HOMUN_APPROVE_LEGACY=1 forces the legacy path. A Python file on purpose: callers run it as
`sh <this file>` or `python3 <this file>`; stdin passes through."""

import os
import shutil
import subprocess
import sys

here = os.path.dirname(os.path.realpath(__file__))
homund = shutil.which(os.environ.get("HOMUND", "homund"))
if os.environ.get("HOMUN_APPROVE_LEGACY") != "1" and homund:
    probe = subprocess.run([homund, "approve", "--help"], capture_output=True)
    if probe.returncode == 0:
        os.execv(homund, [homund, "approve", *sys.argv[1:]])
os.execv("/bin/sh", ["sh", os.path.join(here, "permission-hook-legacy.sh"), *sys.argv[1:]])
