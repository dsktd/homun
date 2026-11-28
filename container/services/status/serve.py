"""Status page of the Manager: agents, services, schedules, issues, usage.

    serve.py [port]

Binds 127.0.0.1 only. GET / is the page (meta refresh every 10 s), GET /status.json the same data.
Links are relative, so the page also works behind the proxy service at /status/.
Each source degrades to an error note when its tool or file is missing.
Environment: CLAUDE_SERVICES_DIR (default ~/claude/.services), STATUS_TRACKER (the tracker command, default `tracker`),
USAGE_URL (default http://127.0.0.1:8420).
"""

import glob
import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
import urllib.request
from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# run.nu starts this with python3 -I, which leaves the script's own directory off sys.path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import host
import strays

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8421
SERVICES = os.environ.get("CLAUDE_SERVICES_DIR") or os.path.expanduser(
    "~/claude/.services"
)
SCAN = os.environ.get("CLAUDE_SERVICES_SCAN") or "/run/claude-services"
TRACKER = shlex.split(os.environ.get("STATUS_TRACKER", "tracker"))
USAGE = os.environ.get("USAGE_URL", "http://127.0.0.1:8420")
STATES = ["doing", "next", "wait", "todo"]
REFRESH = 10

SOURCE_ERRORS = (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError)
_cache = {}
_lock = threading.Lock()


def cached(key, ttl, fn):
    """fn() -> data, or raises; failures are cached for a short while too, so a broken source is not retried per request."""
    with _lock:
        hit = _cache.get(key)
        if hit and time.time() - hit[0] < (ttl if hit[1] is None else min(ttl, 15)):
            return hit[2] if hit[1] is None else {"error": hit[1]}
        try:
            val, err = fn(), None
        except SOURCE_ERRORS as e:  # a failing source is shown, not fatal
            val, err = None, f"{type(e).__name__}: {e}"[:200]
        _cache[key] = (time.time(), err, val)
        return val if err is None else {"error": err}


def run(*cmd, timeout=15):
    return subprocess.run(
        cmd, capture_output=True, text=True, timeout=timeout, check=True
    ).stdout


def agents():
    out = json.loads(run("claude", "agents", "--json"))
    now = time.time()
    return [
        {
            "name": a.get("name") or a.get("id"),
            "status": a.get("state") or a.get("status"),
            "kind": a.get("kind"),
            "model": a.get("model"),
            "age_s": int(now - a["startedAt"] / 1000) if a.get("startedAt") else None,
        }
        for a in out
    ]


def alive(name):
    """Whether runit's supervisor for the service reports it up, as `claude-services list` does: a pid-and-cwd test missed services whose run script changes directory."""
    try:
        with open(os.path.join(SCAN, name, "supervise", "stat")) as f:
            return f.read().strip() == "run"
    except OSError:
        return False


def services():
    out = []
    for name in sorted(os.listdir(SERVICES)):
        d = os.path.join(SERVICES, name)
        if not os.access(os.path.join(d, "run"), os.X_OK):
            continue

        def read(f, d=d):
            try:
                return open(os.path.join(d, f)).read()
            except OSError:
                return ""

        port = next(
            (
                l.split("=", 1)[1].strip()
                for l in read("env").splitlines()
                if l.startswith("PORT=")
            ),
            "",
        )
        if alive(name):
            state = "running"
        else:
            state = (
                "disabled" if os.path.exists(os.path.join(d, "disabled")) else "stopped"
            )
        out.append({"name": name, "port": port or None, "state": state})
    return out


def schedules():
    path = os.path.join(SERVICES, "sched", "schedules.nuon")
    if not os.path.exists(path):
        return []
    env = {**os.environ, "STATUS_SCHED": path}
    out = subprocess.run(
        ["nu", "-c", "open $env.STATUS_SCHED | to json"],
        capture_output=True,
        text=True,
        timeout=10,
        check=True,
        env=env,
    ).stdout
    return json.loads(out)


def issues():
    groups = {s: [] for s in STATES}
    for i in json.loads(run(*TRACKER, "list", "state", "open")):
        groups.setdefault(i["state"].lower(), []).append(
            {"number": i["id"], "title": i["title"], "url": "", "labels": i["tags"]}
        )
    return groups


def usage():
    with urllib.request.urlopen(f"{USAGE}/forecast.json", timeout=5) as r:
        f = json.load(r)
    f.pop("series", None)
    f.get("owner", {}).pop("profile", None)
    return f


HOME = os.path.expanduser("~/claude")
WORKER = ["python3", os.path.join(HOME, "_tools/homun/bin/claude-worker")]
TOKENISH = re.compile(
    r"(sk-[\w-]{8,}|gh[pousr]_\w{8,}|github_pat_\w+|\b[A-Za-z0-9+_=-]{32,}\b)"
)


def redact(t):
    return TOKENISH.sub("[redacted]", t)


def tail(path, n):
    with open(path, "rb") as f:
        f.seek(0, 2)
        f.seek(max(0, f.tell() - 65536))
        return f.read().decode("utf-8", "replace").splitlines()[-n:]


def board():
    out, cur = {}, None
    path = os.path.join(HOME, "nx2navi/.lab/BOARD.md")
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("## "):
                cur = line[3:].strip()
                out[cur] = []
            elif cur in ("Working now", "GPU queue", "Fresh findings") and line.strip():
                out[cur].append(redact(line.strip()))
    return {k: v for k, v in out.items() if v}


def feed():
    return [
        redact(l)
        for l in tail(os.path.join(SERVICES, "screensavers/feeds/nx2navi-lab.log"), 40)
    ][::-1]


def workers():
    rows = [l.split() for l in run(*WORKER, "list").splitlines() if l.strip()]
    bal = [l.strip() for l in run(*WORKER, "balance").splitlines() if l.strip()]
    return {"rows": [redact(" ".join(r)) for r in rows[-15:]][::-1], "balance": bal}


FT = re.compile(r"frametime: 60 s:.*1% low.*")


def game():
    logs = glob.glob(os.path.join(HOME, "nx2navi/NX2navi/build/*/logs/play-*.log"))
    if not logs:
        raise OSError("no play log")
    p = max(logs, key=os.path.getmtime)
    age = int(time.time() - os.path.getmtime(p))
    ft = next((m.group(0) for l in reversed(tail(p, 400)) if (m := FT.search(l))), None)
    return {
        "log": os.path.basename(p),
        "age_s": age,
        "running": age < 120,
        "frametime": redact(ft) if ft else None,
    }


def commits():
    out = []
    for repo, refs in (
        ("NX2navi", ["main", "build", "rebase-upstream", "tool-*"]),
        ("yakin", ["history", "ui-*"]),
    ):
        args = [
            "git",
            "-C",
            os.path.join(HOME, ".bare", repo + ".git"),
            "log",
            "-n",
            "10",
            "--source",
            "--format=%ct\t%S\t%h\t%s",
        ]
        for r in refs:
            args += ["--glob=refs/heads/" + r]
        for l in run(*args).splitlines():
            t, ref, h, subj = l.split("\t", 3)
            out.append(
                {
                    "repo": repo,
                    "ts": int(t),
                    "branch": ref.replace("refs/heads/", ""),
                    "hash": h,
                    "subject": redact(subj),
                }
            )
    return out


def lab():
    return {
        "board": cached("board", 5, board),
        "feed": cached("feed", 5, feed),
        "workers": cached("workers", 8, workers),
        "game": cached("game", 3, game),
        "commits": cached("commits", 15, commits),
    }


def gather():
    return {
        "now": int(time.time()),
        "agents": cached("agents", 10, agents),
        "services": cached("services", 0, services),
        "schedules": cached("schedules", 30, schedules),
        "issues": cached("issues", 120, issues),
        "usage": cached("usage", 20, usage),
        "strays": cached("strays", 60, strays.strays),
        "host": cached("host", 10, host.host),
        **lab(),
    }


CSS = """
:root{--bg:#fafafa;--fg:#1c1c1e;--mut:#6b6b70;--card:#fff;--line:#d9d9de;--ok:#1a7f37;--bad:#b3261e;--link:#0b57d0}
@media(prefers-color-scheme:dark){:root{--bg:#161618;--fg:#e6e6ea;--mut:#9a9aa2;--card:#1f1f23;--line:#38383e;--ok:#4cc26a;--bad:#f2766d;--link:#8ab4f8}}
body{margin:0;padding:16px;background:var(--bg);color:var(--fg);font:15px/1.45 system-ui,sans-serif;max-width:900px;margin-inline:auto}
h1{font-size:1.3rem;margin:.2em 0}h2{font-size:1.05rem;margin:0 0 .5em}h3{font-size:.9rem;margin:.8em 0 .2em;color:var(--mut)}
section{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px 14px;margin:12px 0;overflow-x:auto}
table{border-collapse:collapse;width:100%}td,th{text-align:left;padding:3px 10px 3px 0;white-space:nowrap}th{color:var(--mut);font-weight:500}
a{color:var(--link)}.feed{font:12px/1.4 ui-monospace,monospace;white-space:pre-wrap;word-break:break-word;margin:0}.feed div{padding:1px 0}
.k-result{color:var(--ok);font-weight:600}.k-learned{color:var(--link)}.k-suspect{color:var(--bad)}.k-step{color:var(--mut)}
.mut{color:var(--mut)}.ok{color:var(--ok)}.bad{color:var(--bad)}ul{margin:.2em 0;padding-left:1.2em}
"""


def ago(s):
    if s is None:
        return "?"
    for unit, n in (("d", 86400), ("h", 3600), ("m", 60)):
        if s >= n:
            return f"{s // n}{unit}"
    return f"{s}s"


def fnum(v, suffix=""):
    return (
        "?"
        if v is None
        else f"{v:.1f}{suffix}" if isinstance(v, float) else f"{v}{suffix}"
    )


def table(head, rows):
    h = "".join(f"<th>{escape(c)}</th>" for c in head)
    body = "".join("<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>" for r in rows)
    return f"<table><tr>{h}</tr>{body}</table>"


def section(title, data, render):
    if isinstance(data, dict) and "error" in data:
        body = f'<p class="mut">Unavailable: {escape(data["error"])}</p>'
    else:
        body = render(data)
    return f"<section><h2>{title}</h2>{body}</section>"


def r_agents(a):
    if not a:
        return '<p class="mut">No agents.</p>'
    return table(
        ["name", "status", "kind", "model", "age"],
        [
            [
                escape(str(x["name"])),
                escape(str(x["status"])),
                escape(str(x["kind"] or "")),
                escape(str(x["model"] or "-")),
                ago(x["age_s"]),
            ]
            for x in a
        ],
    )


def r_services(s):
    rows = []
    for x in s:
        name = escape(x["name"])
        link = (
            f'<a href="../{name}/">{name}</a>'
            if x["port"] and x["state"] == "running"
            else name
        )
        cls = (
            "ok"
            if x["state"] == "running"
            else "bad" if x["state"] == "stopped" else "mut"
        )
        rows.append(
            [link, escape(x["port"] or "-"), f'<span class="{cls}">{x["state"]}</span>']
        )
    return (
        table(["service", "port", "state"], rows)
        if rows
        else '<p class="mut">No services.</p>'
    )


def r_strays(s):
    rows = [[x["pid"], ago(x["age_s"]), x["why"], escape(x["cmd"][:90])] for x in s]
    return (
        table(["pid", "age", "why", "command"], rows)
        if rows
        else '<p class="ok">None.</p>'
    )


def r_schedules(s):
    if not s:
        return '<p class="mut">No schedules.</p>'
    rows = [
        [
            escape(str(x.get("name", ""))),
            escape(str(x.get("cron", ""))),
            escape(str(x.get("target", ""))),
            "off" if x.get("enabled") is False else "on",
        ]
        for x in s
    ]
    return table(["name", "cron", "target", ""], rows)


def r_issues(g):
    out = []
    for state, items in g.items():
        if not items:
            continue
        lis = "".join(
            f'<li>#{i["number"]} {escape(i["title"])} '
            f'<span class="mut">{escape(" ".join(i["labels"]))}</span></li>'
            for i in items
        )
        out.append(f"<h3>{escape(state)} ({len(items)})</h3><ul>{lis}</ul>")
    return "".join(out) or '<p class="mut">No open issues.</p>'


def r_usage(u):
    rows = []
    for key, label in (("five_hour", "5-hour"), ("seven_day", "7-day")):
        w = u.get(key) or {}
        rows.append(
            [
                label,
                fnum(w.get("used"), "%"),
                fnum(w.get("rate_per_hour"), "%/h"),
                fnum(w.get("projected_at_reset"), "%"),
                fnum(w.get("hours_left"), " h"),
            ]
        )
    rec = u.get("recommend") or {}
    ov = u.get("mode_override")
    mode = (
        f'<p>Resource mode: <b>{escape(str(u.get("mode", "?")))}</b>'
        + (
            f' (override: {escape(str(ov.get("reason")))}; forecast proposes {escape(str(u.get("mode_proposed")))})'
            if ov
            else ""
        )
        + "</p>"
    )
    return (
        mode
        + table(["window", "used", "rate", "at reset", "resets in"], rows)
        + f'<p class="mut">Recommended agent slots: {escape(str(rec.get("agent_slots", "?")))} of {escape(str(rec.get("max_slots", "?")))}.'
        ' <a href="../usage-db/">Charts and forecast</a></p>'
    )


def r_board(b):
    if not b:
        return '<p class="mut">Board empty.</p>'
    return "".join(
        f"<h3>{escape(k)}</h3><ul>"
        + "".join(f"<li>{escape(l.lstrip('- '))}</li>" for l in v)
        + "</ul>"
        for k, v in b.items()
    )


def r_feed(f):
    def row(l):
        m = re.match(r"\d\d:\d\d (run|step|suspect|learned|result)\b", l)
        cls = f"k-{m.group(1)}" if m else ""
        return f'<div class="{cls}">{escape(l)}</div>'

    return (
        '<div class="feed">' + "".join(row(l) for l in f) + "</div>"
        if f
        else '<p class="mut">Feed empty.</p>'
    )


def r_workers(w):
    bal = " | ".join(escape(b) for b in w["balance"])
    rows = "".join(
        f"<div>{escape(r)}</div>"
        for r in sorted(w["rows"], key=lambda r: "running" not in r)
    )
    return f'<p><b>{bal}</b></p><div class="feed">{rows or "none"}</div>'


def r_game(g):
    state = (
        '<span class="ok">game running</span>'
        if g["running"]
        else '<span class="mut">game not running</span>'
    )
    return f'<p>{state}, log {escape(g["log"])} written {ago(g["age_s"])} ago</p><p>{escape(g["frametime"] or "no frametime line yet")}</p>'


def r_commits(c):
    rows = [
        [
            ago(max(0, int(time.time()) - x["ts"])),
            escape(x["repo"]),
            escape(x["branch"]),
            escape(x["hash"]),
            escape(x["subject"][:90]),
        ]
        for x in sorted(c, key=lambda x: -x["ts"])
    ]
    return table(["age", "repo", "branch", "hash", "subject"], rows)


def page(d):
    parts = [
        section("Game", d["game"], r_game),
        section("Lab board", d["board"], r_board),
        section("Lab feed", d["feed"], r_feed),
        section("API workers", d["workers"], r_workers),
        section("Commits", d["commits"], r_commits),
        section("Agents", d["agents"], r_agents),
        section("Services", d["services"], r_services),
        section("Stray processes", d["strays"], r_strays),
        section("Schedules", d["schedules"], r_schedules),
        section("Issues", d["issues"], r_issues),
        section("Usage", d["usage"], r_usage),
    ]
    stamp = time.strftime("%H:%M:%S", time.localtime(d["now"]))
    return (
        f'<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
        f'<meta http-equiv="refresh" content="{REFRESH}"><title>Manager status</title><style>{CSS}</style>'
        f'<h1>Manager status</h1><p class="mut">Updated {stamp}, refreshes every {REFRESH} s. <a href="status.json">JSON</a></p>'
        + "".join(parts)
    )


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        route = self.path.split("?")[0]
        if route == "/status.json":
            body, ctype = json.dumps(gather()).encode(), "application/json"
        elif route == "/":
            body, ctype = page(gather()).encode(), "text/html; charset=utf-8"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


def write_loop(path, every=30):
    """status.json for readers in other containers, which cannot reach this port."""
    while True:
        try:
            tmp = f"{path}.tmp"
            with open(tmp, "w") as f:
                json.dump(gather(), f)
            os.replace(tmp, path)
        except Exception:  # noqa: BLE001,S110
            pass  # the sampler must outlive any gather() failure
        time.sleep(every)


if __name__ == "__main__":
    threading.Thread(
        target=write_loop,
        args=(os.path.join(os.path.dirname(os.path.abspath(__file__)), "status.json"),),
        daemon=True,
    ).start()
    class Server(ThreadingHTTPServer):
        def handle_error(self, request, client_address):
            # A browser that closes its tab mid-reply is not an error worth a traceback
            if not isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
                super().handle_error(request, client_address)

    Server(("127.0.0.1", PORT), Handler).serve_forever()
