#!/usr/bin/env python3
"""Usage forecast from usage.sqlite (filled by import.nu) and ~/.claude/history.jsonl.

    forecast.py <db> [--since HOURS] [--history FILE] [--now EPOCH] [--state DIR] [--persist]   # prints JSON

Shared by `claude-usage forecast` and serve.py (/forecast.json and the page), so both
show the same numbers. Python stdlib only. All hours and weekdays are UTC.
"""
import json
import math
import os
import sqlite3
import sys
import time
from datetime import datetime, timezone

HOUR = 3600
# Resource mode: how freely the Manager may spend tokens. Deterministic, from the projections
# at the two resets (percent of the limit, at the recent rate) and the time left. Strictest first.
MODES = ["hold", "frugal", "normal", "burn"]
MODE_SLOTS = {"hold": 0, "frugal": 1, "normal": 2, "burn": 3}  # agent slots the Manager may run at once
MODE_RULES = {
    "hold":   {"used5": 90, "used7": 95, "proj7": 105},  # any value at or above its threshold
    "frugal": {"proj5": 100, "proj7": 90},               # any value at or above its threshold
    "burn":   {"proj5": 70, "proj7": 60},                # all values at or below their threshold
}                                                         # normal: none of the above
MODE_TOLERANCE = 5     # points: a mode is kept until its thresholds are crossed by this much
MODE_MIN_DWELL = 1800  # seconds a mode lasts before a loosening is accepted (tightening is immediate)
LATE_7D_HOURS = 48     # "late" in the 7d window: this many hours or fewer left ...
SURPLUS_MARGIN = 15    # ... and projected 7d use at least this many points under 100: one mode step up
MIN_LEFT_5H = 25       # no agent slots when less than this percent of the 5h window is left
GAP_SLOTS = [(50, 3), (65, 2), (80, 1)]  # (projected 7d use at the reset below this, slots the unspent week justifies)
STATE_FILES = {"state": "mode-state.json", "override": "mode-override.json", "badge": "mode"}
PROFILE_DAYS = 28
DEFAULT_SINCE = 3.0  # hours of recent history for the burn rates


def _rises(rows, key, reset_key):
    """[(ts, rise)]: increase of the running maximum of `key` within each window.
    A status line of an older session can show a stale lower value; the running
    maximum ignores it, and a new resets_at starts a new window."""
    out, win, top = [], None, None
    for r in rows:
        v, w = r[key], r[reset_key]
        if v is None or w is None:
            continue
        if w != win:
            win, top = w, v
            continue
        if v > top:
            out.append((r["ts"], v - top))
            top = v
    return out


def _sum(rises, lo, hi=float("inf")):
    return sum(d for t, d in rises if lo <= t < hi)


def _activity(history, now):
    """Probability that the Prime is active in each (weekday, hour) slot: the share
    of the observed days with that weekday that had a prompt in that hour."""
    stamps = []
    if history and os.path.exists(history):
        with open(history, errors="replace") as f:
            for line in f:
                try:
                    stamps.append(json.loads(line)["timestamp"] / 1000)
                except (ValueError, KeyError, TypeError):
                    pass
    lo = now - PROFILE_DAYS * 86400
    stamps = [t for t in stamps if lo <= t <= now]
    if not stamps:
        return [[0.0] * 24 for _ in range(7)], 0, set()
    first_day = int(min(stamps) // 86400)
    last_day = int(now // 86400)
    days_per_wd = [0] * 7
    for d in range(first_day, last_day + 1):
        days_per_wd[datetime.fromtimestamp(d * 86400, timezone.utc).weekday()] += 1
    seen = {(int(t // HOUR)) for t in stamps}  # active hour numbers since epoch
    slots = {}
    for h in seen:
        dt = datetime.fromtimestamp(h * HOUR, timezone.utc)
        slots.setdefault((dt.weekday(), dt.hour), set()).add(h // 24)
    prof = [[0.0] * 24 for _ in range(7)]
    for (wd, hr), ds in slots.items():
        prof[wd][hr] = min(1.0, len(ds) / max(days_per_wd[wd], 1))
    return prof, len(stamps), seen


def _expected_hours(prof, start, end):
    """Expected number of Prime-active hours in [start, end)."""
    total, t = 0.0, start
    while t < end:
        nxt = min((int(t // HOUR) + 1) * HOUR, end)
        dt = datetime.fromtimestamp(t, timezone.utc)
        total += prof[dt.weekday()][dt.hour] * (nxt - t) / HOUR
        t = nxt
    return total


def _read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _write(path, text):
    tmp = f"{path}.tmp{os.getpid()}"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def propose_mode(v, current, since, now):
    """Mode from the values `v` (used5, used7, proj5, proj7, h7). `current` and `since` (when it
    began) give the hysteresis: a mode needs MODE_TOLERANCE more to be left than to be entered,
    and a loosening waits MODE_MIN_DWELL."""
    cur = MODES.index(current) if current in MODES else MODES.index("normal")
    tol = lambda mode: MODE_TOLERANCE if cur <= MODES.index(mode) else 0  # staying in, or stricter
    def hit(mode):
        return any(v[k] >= t - tol(mode) for k, t in MODE_RULES[mode].items())
    if hit("hold"):
        mode = "hold"
    elif hit("frugal"):
        mode = "frugal"
    elif all(v[k] <= t + (MODE_TOLERANCE if current == "burn" else 0) for k, t in MODE_RULES["burn"].items()):
        mode = "burn"
    else:
        mode = "normal"
    if mode != "hold" and v["h7"] <= LATE_7D_HOURS and v["proj7"] <= 100 - SURPLUS_MARGIN:
        mode = MODES[min(MODES.index(mode) + 1, len(MODES) - 1)]
    if current in MODES and MODES.index(mode) > cur and since and now - since < MODE_MIN_DWELL:
        mode = current
    return mode


def resolve_mode(values, state_dir, now, persist):
    """(effective, proposed, override, since): the proposal persisted in mode-state.json, the
    Manager's override from mode-override.json while it has not expired."""
    st = _read_json(os.path.join(state_dir, STATE_FILES["state"])) or {}
    proposed = propose_mode(values, st.get("mode"), st.get("since"), now)
    since = st.get("since") if proposed == st.get("mode") and st.get("since") else now
    ov = _read_json(os.path.join(state_dir, STATE_FILES["override"]))
    if not (isinstance(ov, dict) and ov.get("mode") in MODES and isinstance(ov.get("until"), (int, float))
            and not isinstance(ov["until"], bool) and ov["until"] > now):
        ov = None  # absent, malformed (a hand-edited file must not break the page) or expired
    else:
        ov = {"mode": ov["mode"], "reason": str(ov.get("reason", "")), "until": ov["until"]}
    effective = ov["mode"] if ov else proposed
    if persist:
        _write(os.path.join(state_dir, STATE_FILES["state"]), json.dumps({"mode": proposed, "since": since}))
        _write(os.path.join(state_dir, STATE_FILES["badge"]), f"{effective} {'override' if ov else '-'} {now}\n")
    return effective, proposed, ov, since


HISTORY_HEARTBEAT = HOUR  # mode_history gets a row at least this often even when nothing changed


def record_mode(db, now, mode, proposed, override, slots, slots_reason, used5, used7, proj7):
    """Append a mode_history row when the mode, proposal, override, slots or their reason differ from
    the last row, or the last row is a heartbeat old (so the series has points to chart between changes)."""
    con = sqlite3.connect(db, timeout=2)  # runs on page views: do not wait long behind the importer
    try:
        con.execute("create table if not exists mode_history (ts integer primary key, mode text, proposed text, "
                    "override integer, slots integer, slots_reason text, five_hour_used real, seven_day_used real, proj7 real)")
        row = (mode, proposed, 1 if override else 0, slots, slots_reason)
        last = con.execute("select ts, mode, proposed, override, slots, slots_reason from mode_history order by ts desc limit 1").fetchone()
        if last is None or tuple(last[1:]) != row or now - last[0] >= HISTORY_HEARTBEAT:
            con.execute("insert or ignore into mode_history values (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                        (now, *row, used5, used7, proj7))
        con.commit()
    finally:
        con.close()


def forecast(db, history=None, now=None, since_hours=DEFAULT_SINCE, persist=False, state_dir=None):
    """persist: also record the proposed mode, write the badge file for the status line and append to mode_history."""
    now = int(now or time.time())
    state_dir = state_dir or os.path.dirname(os.path.abspath(db))
    history = history or os.path.join(os.path.expanduser("~"), ".claude", "history.jsonl")
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    try:
        samples = con.execute(
            "select ts, five_hour_used, five_hour_resets_at, seven_day_used, seven_day_resets_at "
            "from samples where ts >= ? and ts <= ? order by ts, rowid", (now - 8 * 86400, now)).fetchall()
        msgs = con.execute(
            "select ts, agent_id, cost_usd from message_costs where ts >= ? and ts <= ?",
            (now - 8 * 86400, now)).fetchall()
    finally:
        con.close()
    if not samples:
        return {"error": "no samples", "now": now}

    # the status line leaves fields empty at times (and so does a session without limits):
    # the current windows come from the latest sample that has each one
    reset5 = next((s["five_hour_resets_at"] for s in reversed(samples) if s["five_hour_resets_at"] is not None), None)
    reset7 = next((s["seven_day_resets_at"] for s in reversed(samples) if s["seven_day_resets_at"] is not None), None)
    used5_raw = next((s["five_hour_used"] for s in reversed(samples) if s["five_hour_used"] is not None and s["five_hour_resets_at"] == reset5), 0.0)
    used7_raw = next((s["seven_day_used"] for s in reversed(samples) if s["seven_day_used"] is not None and s["seven_day_resets_at"] == reset7), 0.0)
    r5 = _rises(samples, "five_hour_used", "five_hour_resets_at")
    r7 = _rises(samples, "seven_day_used", "seven_day_resets_at")
    # a window that has already rolled over without a newer sample counts as unused
    used5 = used5_raw if reset5 and reset5 > now else 0.0
    used7 = used7_raw if reset7 and reset7 > now else 0.0
    h5 = (reset5 - now) / HOUR if reset5 and reset5 > now else 5.0  # a fresh window starts with the next prompt
    h7 = (reset7 - now) / HOUR if reset7 and reset7 > now else 0.0

    since = since_hours * HOUR
    rate5 = _sum(r5, now - since) / since_hours       # 5h points per hour, recent
    rate7 = _sum(r7, now - since) / since_hours       # 7d points per hour, recent
    start7 = (reset7 or now) - 7 * 86400
    avg7 = used7 / max((now - start7) / HOUR, 1.0)    # 7d points per hour over the window so far
    day7 = _sum(r7, now - 86400) / 24                 # last 24 hours

    # Manager (main sessions) vs agents: cost share over the same recent span
    recent = [m for m in msgs if m["ts"] >= now - since]
    main_c = sum(m["cost_usd"] or 0 for m in recent if m["agent_id"] is None)
    agent_c = sum(m["cost_usd"] or 0 for m in recent if m["agent_id"] is not None)
    tot_c = main_c + agent_c
    share_agents = agent_c / tot_c if tot_c else None
    split = {
        "manager_usd": round(main_c, 2), "agents_usd": round(agent_c, 2),
        "agents_share": share_agents,
        "manager_5h_per_hour": None if share_agents is None else rate5 * (1 - share_agents),
        "agents_5h_per_hour": None if share_agents is None else rate5 * share_agents,
    }
    # per agent-slot burn: agent $/hour while running, converted to 5h points via $ per point (week)
    wk_c = sum(m["cost_usd"] or 0 for m in msgs)
    wk_p5 = _sum(r5, now - 8 * 86400)
    wk_p7 = _sum(r7, now - 8 * 86400)
    usd_per_p5 = wk_c / wk_p5 if wk_p5 > 0 else None
    runs = {}
    for m in msgs:
        if m["agent_id"] is not None:
            a = runs.setdefault(m["agent_id"], [m["ts"], m["ts"], 0.0])
            a[0], a[1], a[2] = min(a[0], m["ts"]), max(a[1], m["ts"]), a[2] + (m["cost_usd"] or 0)
    rates = sorted(c / (max(b - a, 300) / HOUR) for a, b, c in runs.values() if c > 0)
    agent_usd_h = rates[len(rates) // 2] if rates else None
    slot5 = agent_usd_h / usd_per_p5 if agent_usd_h and usd_per_p5 else None  # 5h points/hour per running agent
    p5_per_p7 = wk_p5 / wk_p7 if wk_p7 > 0 else None  # 5h points per 7d point

    # Prime profile and what to reserve for the Prime's expected hours
    prof, nprompts, active_hours = _activity(history, now)
    hourly5, hourly7 = {}, {}
    for t, d in r5:
        hourly5[int(t // HOUR)] = hourly5.get(int(t // HOUR), 0) + d
    for t, d in r7:
        hourly7[int(t // HOUR)] = hourly7.get(int(t // HOUR), 0) + d
    act = [h for h in active_hours if now - 8 * 86400 <= h * HOUR <= now]
    owner5 = sum(hourly5.get(h, 0) for h in act) / len(act) if act else 0.0  # 5h points per active hour
    owner7 = sum(hourly7.get(h, 0) for h in act) / len(act) if act else 0.0
    exp5 = _expected_hours(prof, now, now + h5 * HOUR)
    exp7 = _expected_hours(prof, now, now + h7 * HOUR)
    reserve5 = min(owner5 * exp5, max(100 - used5, 0))
    reserve7 = min(owner7 * exp7, max(100 - used7, 0))

    # Projection to the resets at the recent rate (7d: the higher of the recent and 24h rate)
    proj5 = used5 + rate5 * h5
    proj7 = used7 + max(rate7, day7) * h7

    def when(used, rate, hrs):
        if rate <= 0 or used >= 100:
            return now if used >= 100 else None
        t = (100 - used) / rate
        return int(now + t * HOUR) if t < hrs else None

    # Allowance: 7d points not needed by the Prime, spread evenly to the 7d reset; the 5h window
    # the same with what the Prime is expected to use before its reset.
    free7 = max(100 - used7 - reserve7, 0)
    allow7_h = free7 / h7 if h7 > 0 else 0.0
    free5 = max(100 - used5 - reserve5, 0)
    allow5_h = free5 / max(h5, 1.0)
    allow_h_5 = min(allow5_h, allow7_h * p5_per_p7) if p5_per_p7 else allow5_h
    mode, proposed, override, mode_since = resolve_mode(
        {"used5": used5, "used7": used7, "proj5": proj5, "proj7": proj7, "h7": h7}, state_dir, now, persist)
    mode_slots = MODE_SLOTS[mode]
    slots, slots_reason = mode_slots, "mode"
    if used5 > 100 - MIN_LEFT_5H:
        slots, slots_reason = 0, "5h window nearly spent"
    elif slot5:  # the 7d pace caps what the mode would allow ...
        pace_slots = min(mode_slots, max(0, math.floor(allow_h_5 / slot5)))
        # ... unless the week is projected to end well under budget: that gap is spent on agents
        gap_slots = min(mode_slots, max([n for lim, n in GAP_SLOTS if proj7 < lim], default=0))
        slots = max(pace_slots, gap_slots)
        slots_reason = ("7d gap: projected %d%% at the reset leaves the week unspent" % round(proj7)) if gap_slots > pace_slots \
            else ("7d pace caps the mode" if pace_slots < mode_slots else "mode")
    if persist:  # the status line shows "<mode> <override|-> <epoch> <slots>"
        _write(os.path.join(state_dir, STATE_FILES["badge"]), f"{mode} {'override' if override else '-'} {now} {slots}\n")
        try:  # the history is a nicety: a locked or read-only database must not break the badge
            record_mode(db, now, mode, proposed, override, slots, slots_reason, used5, used7, proj7)
        except sqlite3.Error:
            pass
    # Last hour before a 5h reset: what is left of the window is lost, so only the 7d pace limits it
    leftover5 = max(100 - used5 - (reserve5 if h5 <= 1 else 0), 0)
    leftover = {
        "in_last_hour": h5 <= 1, "left_5h": 100 - used5, "burn_5h_points": leftover5 if h5 <= 1 else 0,
        "cost_7d_points": (leftover5 / p5_per_p7 if p5_per_p7 else None) if h5 <= 1 else 0,
        "safe": bool(h5 <= 1 and (not p5_per_p7 or leftover5 / p5_per_p7 <= free7)),
    }
    thin = {}  # last sample of every 10 minutes keeps the series small
    for s in samples:
        if s["five_hour_used"] is None and s["seven_day_used"] is None:
            continue
        thin[s["ts"] // 600] = {"ts": s["ts"], "five_hour_used": s["five_hour_used"], "seven_day_used": s["seven_day_used"]}
    series = list(thin.values())
    return {
        "now": now, "since_hours": since_hours,
        "mode": mode, "mode_proposed": proposed, "mode_since": mode_since, "mode_override": override, "slots": slots, "slots_reason": slots_reason,
        "five_hour": {"used": used5, "resets_at": reset5, "hours_left": h5, "rate_per_hour": rate5,
                      "projected_at_reset": proj5, "exhausted_at": when(used5, rate5, h5)},
        "seven_day": {"used": used7, "resets_at": reset7, "hours_left": h7, "rate_per_hour": rate7,
                      "avg_per_hour": avg7, "last_24h_per_hour": day7, "projected_at_reset": proj7,
                      "exhausted_at": when(used7, max(rate7, day7), h7), "pace_per_day": (100 - used7) / (h7 / 24) if h7 else None},
        "split": split,
        "agent_slot": {"usd_per_hour": agent_usd_h, "five_hour_per_hour": slot5, "runs": len(runs),
                       "usd_per_5h_point": usd_per_p5, "p5_per_p7": p5_per_p7},
        "owner": {"prompts": nprompts, "profile_days": PROFILE_DAYS, "five_hour_per_active_hour": owner5,
                  "seven_day_per_active_hour": owner7, "expected_hours_5h": exp5, "expected_hours_7d": exp7,
                  "reserve_5h": reserve5, "reserve_7d": reserve7, "profile": prof},
        "recommend": {"agent_slots": slots, "max_slots": max(MODE_SLOTS.values()), "mode_slots": MODE_SLOTS[mode], "allowance_5h_per_hour": allow_h_5,
                      "allowance_7d_per_hour": allow7_h, "free_7d": free7, "free_5h": free5},
        "leftover": leftover, "series": series,
    }


if __name__ == "__main__":
    a = sys.argv[1:]
    opt = lambda k, d=None: a[a.index(k) + 1] if k in a else d
    print(json.dumps(forecast(a[0], opt("--history"), opt("--now") and int(opt("--now")), float(opt("--since", DEFAULT_SINCE)),
                              "--persist" in a, opt("--state"))))
