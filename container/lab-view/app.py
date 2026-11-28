#!/usr/bin/env python3
"""Lab view: a small window with the current lab job and a live thumbnail of the display it renders on.

  app.py show   open the window (GTK4, app-id homun-lab-view)
  app.py json   print what the window would show, once

The job is the newest registered `claude-job` (name, percent and ETA of a measured step).
The thumbnail is a grim screencopy of the render
display, scaled down, every 2 s; the game's own resolution is never touched.
Environment: LAB_VIEW_SERVICES (default ~/claude/.services), LAB_VIEW_SOURCE (the wayland
runtime dir with the display socket; default gpu-display's), LAB_VIEW_DISPLAY (its socket name).
LAB_VIEW_THUMB=off shows no thumbnail (inside the lab session, wl-mirror is the thumbnail).
"""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SERVICES = Path(os.environ.get("LAB_VIEW_SERVICES", Path.home() / "claude/.services"))
SOURCE = Path(os.environ.get("LAB_VIEW_SOURCE", SERVICES / "gpu-display/runtime"))
DISPLAY = os.environ.get("LAB_VIEW_DISPLAY", "gpu-display")
THUMB = os.environ.get("LAB_VIEW_THUMB") != "off"


def live_job():
    """The newest registered claude-job (name, percent, eta s), or None."""
    jobs = []
    for f in (SERVICES / "jobs/running").glob("*.json"):
        try:
            jobs.append(json.loads(f.read_text()))
        except (OSError, ValueError):
            continue
    return max(jobs, key=lambda j: j.get("since", 0), default=None)


def snapshot():
    """Everything the window shows, as one dict (missing parts are None)."""
    job = live_job()
    out = {"job": None, "run": None, "eta": None}
    if job:
        out["job"] = job.get("name") or job.get("job")
        if job.get("percent") is not None:
            out["run"] = f"{job['percent']:.0f}%"
        out["eta"] = job.get("eta")
    return out


def thumbnail(path):
    """Screencopy the render display, scaled to a quarter, into path; True on success."""
    env = {**os.environ, "XDG_RUNTIME_DIR": str(SOURCE), "WAYLAND_DISPLAY": DISPLAY}
    r = subprocess.run(
        ["grim", "-s", "0.25", path],
        env=env,
        capture_output=True,
        timeout=10,
        check=False,
    )
    return r.returncode == 0


def eta_text(s):
    return "" if s is None else f"ETA {s // 60}:{s % 60:02d}"


def show():
    import gi

    gi.require_version("Gtk", "4.0")
    from gi.repository import GLib, Gtk

    tmp = Path(tempfile.mkdtemp(prefix="lab-view-")) / "thumb.png"

    def on_activate(app):
        win = Gtk.ApplicationWindow(
            application=app, title="Lab view", default_width=520, default_height=420
        )
        box = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=6,
            margin_top=10,
            margin_bottom=10,
            margin_start=10,
            margin_end=10,
        )
        pic = Gtk.Picture(
            can_shrink=True, content_fit=Gtk.ContentFit.CONTAIN, vexpand=True
        )
        text = Gtk.Label(xalign=0, wrap=True, selectable=False)
        if THUMB:
            box.append(pic)
        box.append(text)
        win.set_child(box)

        def tick():
            s = snapshot()
            head = " ".join(
                x
                for x in (
                    s["job"] or "no lab job",
                    s["run"] and f"run {s['run']}",
                    eta_text(s["eta"]),
                )
                if x
            )
            text.set_markup(f"<b>{GLib.markup_escape_text(head)}</b>")
            if THUMB and thumbnail(str(tmp)):
                pic.set_filename(str(tmp))
            return True

        tick()
        GLib.timeout_add_seconds(2, tick)
        win.present()

    GLib.set_prgname(
        "homun-lab-view"
    )  # the Wayland app-id (a GApplication id must contain a dot)
    app = Gtk.Application()
    app.connect("activate", on_activate)
    app.run([])


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
    if cmd == "json":
        print(json.dumps(snapshot(), indent=1))
    elif cmd == "show":
        show()
    else:
        print(__doc__)
