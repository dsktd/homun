#!/usr/bin/env python3
"""Charts of the usage samples in usage.sqlite (filled by import.nu).

    serve.py <db> [port]

Binds 127.0.0.1 only; reach it from the host with `c port open <port>:<port>`.
GET / draws the last 7 days as inline SVG; GET /data.json returns the same series; the forecast (forecast.py) is on the page and at /forecast.json.
Links are relative, so the page also works behind the proxy service at /usage-db/.
"""
import html
import json
import os
import sqlite3
import sys
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python3 -I does not
import forecast as fc  # noqa: E402

DB = sys.argv[1]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8420
DAYS = 7

# Views defined by import.nu; days are UTC there and in the axis labels
SAMPLES = "select ts, five_hour_left, seven_day_left, context_left from samples_left where ts >= ? order by ts"
COST = "select day, cost_usd from cost_per_day where day >= date(?, 'unixepoch') order by day"


def data():
    since = int(time.time()) - DAYS * 86400
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    try:
        rows = con.execute(SAMPLES, (since,)).fetchall()
        cost = con.execute(COST, (since,)).fetchall()
    finally:
        con.close()
    return {
        "since": since,
        "samples": [{"ts": r[0], "five_hour_left": r[1], "seven_day_left": r[2], "context_left": r[3]} for r in rows],
        "cost_per_day": [{"day": d, "cost_usd": round(c, 4)} for d, c in cost],
    }


W, H, PAD = 760, 220, {"l": 40, "r": 16, "t": 16, "b": 28}
SERIES = [("five_hour_left", "5h left"), ("seven_day_left", "7d left"), ("context_left", "context left")]


def lines_chart(samples, since):
    x0, x1 = PAD["l"], W - PAD["r"]
    y0, y1 = H - PAD["b"], PAD["t"]
    now = max([since + DAYS * 86400] + [s["ts"] for s in samples])
    sx = lambda ts: x0 + (ts - since) / (now - since) * (x1 - x0)
    sy = lambda v: y0 - v / 100 * (y0 - y1)
    out = [f'<svg class="chart" viewBox="0 0 {W} {H}" role="img" aria-label="Percent of each budget left over the last {DAYS} days">']
    for v in (0, 50, 100):
        out.append(f'<line class="grid" x1="{x0}" x2="{x1}" y1="{sy(v):.1f}" y2="{sy(v):.1f}"/><text class="tick" x="{x0 - 6}" y="{sy(v) + 4:.1f}" text-anchor="end">{v}%</text>')
    for d in range(DAYS + 1):
        ts = since + d * 86400
        label = datetime.fromtimestamp(ts, timezone.utc).strftime("%a %d")
        out.append(f'<text class="tick" x="{sx(ts):.1f}" y="{H - 8}" text-anchor="middle">{label}</text>')
    for i, (key, label) in enumerate(SERIES):
        pts = [(sx(s["ts"]), sy(s[key])) for s in samples if s[key] is not None]
        if not pts:
            continue
        path = " ".join(f"{'M' if j == 0 else 'L'}{x:.1f} {y:.1f}" for j, (x, y) in enumerate(pts))
        out.append(f'<path class="s{i}" d="{path}"/>')
        out.append(f'<text class="label s{i}" x="{pts[-1][0] + 4:.1f}" y="{pts[-1][1] + 4:.1f}">{label}</text>')
        for s in samples:
            if s[key] is not None:
                t = datetime.fromtimestamp(s["ts"], timezone.utc).strftime("%a %d %b %H:%M")
                out.append(f'<circle class="pt s{i}" cx="{sx(s["ts"]):.1f}" cy="{sy(s[key]):.1f}" r="5"><title>{label}: {s[key]:.0f}% at {t}</title></circle>')
    out.append("</svg>")
    return "".join(out)


def cost_chart(cost):
    x0, x1 = PAD["l"], W - PAD["r"]
    y0, y1 = H - PAD["b"], PAD["t"]
    top = max([c["cost_usd"] for c in cost] + [1.0])
    sy = lambda v: y0 - v / top * (y0 - y1)
    slot = (x1 - x0) / max(len(cost), 1)
    out = [f'<svg class="chart" viewBox="0 0 {W} {H}" role="img" aria-label="Cost per day over the last {DAYS} days">']
    for v in (0, top / 2, top):
        out.append(f'<line class="grid" x1="{x0}" x2="{x1}" y1="{sy(v):.1f}" y2="{sy(v):.1f}"/><text class="tick" x="{x0 - 6}" y="{sy(v) + 4:.1f}" text-anchor="end">${v:.0f}</text>')
    for i, c in enumerate(cost):
        x = x0 + i * slot + slot * 0.2
        w = slot * 0.6
        y = sy(c["cost_usd"])
        out.append(f'<rect class="bar s0" x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{max(y0 - y, 0):.1f}"><title>{c["day"]}: ${c["cost_usd"]:.2f}</title></rect>')
        out.append(f'<text class="tick" x="{x + w / 2:.1f}" y="{H - 8}" text-anchor="middle">{c["day"][5:]}</text>')
        out.append(f'<text class="value" x="{x + w / 2:.1f}" y="{y - 4:.1f}" text-anchor="middle">${c["cost_usd"]:.2f}</text>')
    out.append("</svg>")
    return "".join(out)


def fmt_t(ts):
    return "never" if ts is None else datetime.fromtimestamp(ts).astimezone().strftime("%a %d %H:%M %Z")


def window_chart(f, key, win_h, title):
    """Used % over one window with the projection to its reset as a dashed line."""
    w = f[key]
    reset, now = w["resets_at"], f["now"]
    if not reset or reset <= now:
        return "<p>No active window.</p>"
    start = reset - win_h * 3600
    field = "five_hour_used" if key == "five_hour" else "seven_day_used"
    x0, x1, y0, y1 = PAD["l"], W - PAD["r"], H - PAD["b"], PAD["t"]
    top = max(100, w["projected_at_reset"])
    sx = lambda ts: x0 + (ts - start) / (reset - start) * (x1 - x0)
    sy = lambda v: y0 - min(v, top) / top * (y0 - y1)
    pts = [(sx(s["ts"]), sy(s[field])) for s in f["series"] if start <= s["ts"] <= now and s[field] is not None]
    out = [f'<svg class="chart" viewBox="0 0 {W} {H}" role="img" aria-label="{title}">']
    for v in (0, 50, 100):
        out.append(f'<line class="grid" x1="{x0}" x2="{x1}" y1="{sy(v):.1f}" y2="{sy(v):.1f}"/><text class="tick" x="{x0 - 6}" y="{sy(v) + 4:.1f}" text-anchor="end">{v}%</text>')
    for i in range(0, win_h + 1, 1 if win_h <= 6 else 24):
        ts = start + i * 3600
        lab = datetime.fromtimestamp(ts).astimezone().strftime("%H:%M" if win_h <= 6 else "%a %d")
        out.append(f'<text class="tick" x="{sx(ts):.1f}" y="{H - 8}" text-anchor="middle">{lab}</text>')
    out.append(f'<line class="now" x1="{sx(now):.1f}" x2="{sx(now):.1f}" y1="{y1}" y2="{y0}"/>')
    if pts:
        out.append('<path class="s0" d="%s"/>' % " ".join(f"{'M' if j == 0 else 'L'}{x:.1f} {y:.1f}" for j, (x, y) in enumerate(pts)))
    out.append(f'<path class="s1 proj" d="M{sx(now):.1f} {sy(w["used"]):.1f} L{x1} {sy(w["projected_at_reset"]):.1f}"><title>Projected {w["projected_at_reset"]:.0f}% at reset</title></path>')
    out.append(f'<text class="label" x="{x1 - 4}" y="{sy(w["projected_at_reset"]) - 6:.1f}" text-anchor="end">{w["projected_at_reset"]:.0f}% at reset</text>')
    out.append("</svg>")
    return "".join(out)


def profile_chart(prof):
    """Weekday x hour heatmap of how likely the Prime is active (UTC)."""
    cw, ch, x0, y0 = 28, 22, 40, 4
    out = [f'<svg class="chart" viewBox="0 0 {x0 + 24 * cw} {y0 + 7 * ch + 20}" role="img" aria-label="Prime activity by weekday and hour, UTC">']
    for wd, name in enumerate(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]):
        out.append(f'<text class="tick" x="{x0 - 6}" y="{y0 + wd * ch + 15}" text-anchor="end">{name}</text>')
        for hr in range(24):
            p = prof[wd][hr]
            out.append(f'<rect class="heat" x="{x0 + hr * cw + 1}" y="{y0 + wd * ch + 1}" width="{cw - 2}" height="{ch - 2}" rx="3" style="fill-opacity:{0.06 + 0.94 * p:.2f}"><title>{name} {hr:02d}:00 UTC: active {p * 100:.0f}% of days</title></rect>')
    for hr in range(0, 24, 3):
        out.append(f'<text class="tick" x="{x0 + hr * cw + cw / 2}" y="{y0 + 7 * ch + 14}" text-anchor="middle">{hr:02d}</text>')
    out.append("</svg>")
    return "".join(out)


def forecast_html(f):
    if "error" in f:
        return f"<p>{f['error']}</p>"
    a, b, r, o, lo = f["five_hour"], f["seven_day"], f["recommend"], f["owner"], f["leftover"]
    n = lambda v, d=1: "n/a" if v is None else f"{v:.{d}f}"
    sp = f["split"]
    rows = [
        ("Resource mode", f"<b>{f['mode']}</b>, " + (f"override: {html.escape(f['mode_override']['reason'])} (until {fmt_t(f['mode_override']['until'])}); forecast proposes {f['mode_proposed']}"
                                                     if f["mode_override"] else f"proposed by the forecast since {fmt_t(f['mode_since'])}")),
        ("Recommended now", f"<b>{r['agent_slots']} of {r['max_slots']} agent slots</b>" if r["agent_slots"] is not None else "n/a (no agent history)"),
        ("5h window", f"{a['used']:.0f}% used, {n(a['rate_per_hour'])} pts/h, {n(a['hours_left'])} h to reset ({fmt_t(a['resets_at'])}); projected {a['projected_at_reset']:.0f}%"
                      + (f", runs out {fmt_t(a['exhausted_at'])}" if a["exhausted_at"] else "")),
        ("7d window", f"{b['used']:.0f}% used, {n(b['rate_per_hour'], 2)} pts/h now, {n(b['avg_per_hour'], 2)} pts/h average, reset {fmt_t(b['resets_at'])}; projected {b['projected_at_reset']:.0f}%"
                      + (f", runs out {fmt_t(b['exhausted_at'])}" if b["exhausted_at"] else "")),
        ("7d pace", f"{n(b['pace_per_day'])} pts/day available; {n(r['free_7d'])} pts free after reserving {n(o['reserve_7d'])} for the Prime (~{n(o['expected_hours_7d'])} active hours)"),
        ("Allowance", f"{n(r['allowance_5h_per_hour'], 2)} 5h pts/h for agents (7d pace alone: {n(r['allowance_7d_per_hour'], 2)} 7d pts/h)"),
        ("Burn split", f"agents {n(sp['agents_share'] and sp['agents_share'] * 100, 0)}% of the last {f['since_hours']:g} h (${sp['agents_usd']} agents, ${sp['manager_usd']} Manager)"),
        ("Leftover burn", (f"last hour before the 5h reset: up to {lo['burn_5h_points']:.0f} 5h pts (~{n(lo['cost_7d_points'])} 7d pts), " + ("safe for the 7d pace" if lo["safe"] else "would hurt the 7d pace"))
                          if lo["in_last_hour"] else f"not yet: {n(a['hours_left'])} h to the 5h reset"),
    ]
    table = "<table>" + "".join(f"<tr><th>{k}</th><td>{v}</td></tr>" for k, v in rows) + "</table>"
    return (table + '<h3>5h window, used % with projection</h3>' + window_chart(f, "five_hour", 5, "5 hour window used and projected")
            + '<h3>7d window, used % with projection</h3>' + window_chart(f, "seven_day", 168, "7 day window used and projected")
            + f'<h3>Prime activity (UTC, {o["prompts"]} prompts in {o["profile_days"]} days)</h3>' + profile_chart(o["profile"]))


PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Claude usage</title><style>
:root{--bg:#fcfcfb;--ink:#1a1a19;--muted:#6b6a64;--grid:#e4e3df;--s0:#2a78d6;--s1:#eb6834;--s2:#1baf7a}
@media(prefers-color-scheme:dark){:root{--bg:#1a1a19;--ink:#f0efec;--muted:#a3a29a;--grid:#33332f;--s0:#3987e5;--s1:#d95926;--s2:#199e70}}
body{margin:0;padding:16px;background:var(--bg);color:var(--ink);font:14px/1.4 system-ui,sans-serif;max-width:800px}
h1{font-size:18px;margin:0 0 4px}h2{font-size:14px;font-weight:600;margin:20px 0 4px}p{color:var(--muted);margin:0}
.chart{width:100%;height:auto;display:block}.grid{stroke:var(--grid);stroke-width:1}.tick{fill:var(--muted);font-size:11px}
path.s0,path.s1,path.s2{fill:none;stroke-width:2}path.s0{stroke:var(--s0)}path.s1{stroke:var(--s1)}path.s2{stroke:var(--s2)}
.pt{fill:transparent;stroke:none}.pt:hover{stroke:var(--bg);stroke-width:2}.pt.s0:hover{fill:var(--s0)}.pt.s1:hover{fill:var(--s1)}.pt.s2:hover{fill:var(--s2)}
.label{font-size:11px;fill:var(--ink)}.value{font-size:11px;fill:var(--ink)}.bar{fill:var(--s0);rx:4}.bar:hover{opacity:.8}
table{border-collapse:collapse;width:100%}th{text-align:left;font-weight:600;white-space:nowrap;vertical-align:top;padding:2px 12px 2px 0}td{padding:2px 0}h3{font-size:13px;margin:14px 0 2px;color:var(--muted);font-weight:600}
path.proj{stroke-dasharray:6 4}.now{stroke:var(--muted);stroke-dasharray:2 3}.heat{fill:var(--s0)}
.legend{display:flex;gap:16px;margin:4px 0;color:var(--muted);font-size:12px}.legend i{display:inline-block;width:12px;height:3px;vertical-align:middle;margin-right:4px}
</style></head><body>
<h1>Claude usage</h1><p>Last {{days}} days (UTC), {{n}} samples from {{db}}. <a href="data.json">data.json</a>, <a href="forecast.json">forecast.json</a></p>
<h2>Forecast</h2>
{{forecast}}
<h2>Budget left</h2>
<div class="legend"><span><i style="background:var(--s0)"></i>5h limit</span><span><i style="background:var(--s1)"></i>7d limit</span><span><i style="background:var(--s2)"></i>context</span></div>
{{lines}}
<h2>API-equivalent cost per day (USD, UTC; not a bill)</h2>
{{cost}}
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            if self.path == "/data.json":
                body, ctype = json.dumps(data()).encode(), "application/json"
            elif self.path == "/forecast.json":
                body, ctype = json.dumps(fc.forecast(DB, persist=True)).encode(), "application/json"
            elif self.path == "/":
                d = data()
                fills = {"days": DAYS, "n": len(d["samples"]), "db": DB,
                         "lines": lines_chart(d["samples"], d["since"]), "cost": cost_chart(d["cost_per_day"]),
                         "forecast": forecast_html(fc.forecast(DB, persist=True))}
                body = PAGE
                for key, value in fills.items():
                    body = body.replace("{{%s}}" % key, str(value))
                body = body.encode()
                ctype = "text/html; charset=utf-8"
            else:
                self.send_error(404)
                return
        except Exception as e:  # keep serving; the error goes to the log
            self.send_error(500, str(e))
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
