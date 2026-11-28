#!/usr/bin/env python3
"""Scheduler of the Manager: persistent schedules and two forecast alarms, as plain code (no model).

    serve.py [port]

Reads the schedule table (schedules.nuon, edited by claude-sched, which sends SIGHUP after every change), computes
every next fire time itself and sleeps until the nearest. A fire is delivered to a Ledger: one JSON line
{"ts","alarm","msg"} appended to <state>/events (the Manager tails it with a Monitor), a record in
<state>/history.jsonl (missed=true when the listener heartbeat was stale) and an `events` row in usage.sqlite.
The forecast alarms come from usage-db's /forecast.json: burn-5h (50 min before a 5h reset, only if the reset
was more than 55 min away when first seen), burn-7d (75 min before the 7d reset, likewise more than 80 min away, and
only while the week is projected under 97%), both only when the forecast's burn budget has >= 1 point, and
window-open (5 min after a 5h reset, only with >= 1 agent slot).
The heartbeat is the mtime of HEARTBEAT_PATH, touched by the Manager's listener (or the channel server) and never by this service.

Binds 127.0.0.1 only. GET / is the page, /health.json and /next.json the data, /agenda.org?days=14 the upcoming fires
as an org-agenda file (the Emacs `claude-sched-refresh' fetches it); POST /fire/alarm/<name> and
/fire/table/<name> (header X-Fire: 1) fire one now. Links are relative, so it also works behind the proxy.

Objects, each with one job: Clock, Cron, Heartbeat, Table (+ Entry), Forecast, ResetAlarms, StateFile, Ledger (writes),
History (reads), Book (what the Scheduler knows), Scheduler (acts: reload, run_due, fire_alarm, fire_table,
sleep_seconds), Report (read-only: next, health, recent), Agenda (read-only: render, the org text of the upcoming fires), ScheduleFile (writes schedule.org: the next fire
of each entry) and the HTTP layer (render_page + Handler), which only renders.

Environment: CLAUDE_SERVICES_DIR (default ~/claude/.services), SCHEDULER_DIR (state; default <services>/scheduler),
SCHEDULER_TABLE (default <CLAUDE_SCHED_DIR or <services>/sched>/schedules.nuon), SCHEDULER_DB (default
<services>/usage-db/usage.sqlite), SCHEDULER_FORECAST_URL (default http://127.0.0.1:8420/forecast.json; file:// works),
SCHEDULER_ORG (default <state>/schedule.org), SCHEDULER_NOW (epoch the clock starts at) and SCHEDULER_SPEED (clock speed factor), both for tests.
"""

import json
import os
import re
import signal
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta
from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

BURN_BEFORE_S, BURN_MIN_AWAY_S, OPEN_AFTER_S = 3000, 3300, 300  # 50, 55 and 5 minutes
BURN7_BEFORE_S, BURN7_MIN_AWAY_S = 4500, 4800  # 75 and 80 minutes
BURN7_UNDER = 97  # burn-7d only while the week is projected under this at its reset
LATE_S = (
    600  # a forecast alarm found this late (the service was down) is dropped, not fired
)
HEARTBEAT_PATH = (
    os.environ.get("SCHEDULER_HEARTBEAT") or "/dev/shm/claude-scheduler/listener"
)
STALE_S = 180  # a listener heartbeat older than this is stale
TICK_S = 60  # longest sleep: the forecast is looked at this often
FORECAST_TTL_S = 300
SAME_RESET_S = 600  # resets this close are one reset
ALARMS = ("burn-5h", "burn-7d", "window-open")
WINDOW_ALARMS = {"5h": ("burn-5h", "window-open"), "7d": ("burn-7d",)}
STARTED = time.time()


def log(*parts):
    print("scheduler:", *parts, flush=True)


class Clock:
    """Epoch seconds; SCHEDULER_NOW and SCHEDULER_SPEED make it start elsewhere and run faster (tests)."""

    def __init__(self, start=None, speed=1.0):
        self._real0, self._start, self._speed = time.time(), start or time.time(), speed

    def now(self):
        return self._start + (time.time() - self._real0) * self._speed

    def real_seconds(self, clock_seconds):
        return clock_seconds / self._speed


class CronError(ValueError):
    """The expression is not 5 numeric fields of lists, ranges and steps."""


class Cron:
    """A 5-field cron expression in local time; day-of-week 0-7 (7 is Sunday)."""

    RANGES = ((0, 59), (0, 23), (1, 31), (1, 12), (0, 7))

    def __init__(self, expr):
        self.expr = expr
        fields = expr.split()
        if len(fields) != 5:
            raise CronError(f"needs 5 fields, got {len(fields)}: {expr!r}")
        sets = [self._field(tok, *r) for tok, r in zip(fields, self.RANGES)]
        self._minutes, self._hours = sorted(sets[0]), sorted(sets[1])
        self._dom, self._months = sets[2], sets[3]
        self._dow = {d % 7 for d in sets[4]}
        # vixie cron: with both day fields restricted, either one matching is enough
        self._either_day = not fields[2].startswith("*") and not fields[4].startswith(
            "*"
        )

    @staticmethod
    def _field(token, lo, hi):
        values = set()
        for item in token.split(","):
            span, slash, step = item.partition("/")
            try:
                step = int(step) if slash else 1
                if span == "*":
                    first, last = lo, hi
                elif "-" in span:
                    first, last = (int(x) for x in span.split("-"))
                else:
                    first = int(span)
                    last = hi if slash else first
            except ValueError:
                raise CronError(f"bad field {token!r}") from None
            if step < 1 or not lo <= first <= last <= hi:
                raise CronError(f"bad field {token!r}, allowed {lo}-{hi}")
            values.update(range(first, last + 1, step))
        return values

    def _day_matches(self, day):
        if day.month not in self._months:
            return False
        dom, dow = day.day in self._dom, (day.weekday() + 1) % 7 in self._dow
        return (dom or dow) if self._either_day else (dom and dow)

    def _matches(self, wall):
        return (
            wall.minute in self._minutes
            and wall.hour in self._hours
            and self._day_matches(wall)
        )

    @staticmethod
    def _repeated(t):
        """Whether t is the second pass over a wall-clock hour (a one-hour fall-back)."""
        now = datetime.fromtimestamp(t)
        hour_ago = datetime.fromtimestamp(t - 3600)
        return now == hour_ago

    def _fires_at(self, t):
        """Whether the local wall clock at epoch minute t matches, or a wall minute the clock just skipped did."""
        wall = datetime.fromtimestamp(t)
        if self._matches(wall):
            return len(self._hours) == 24 or not self._repeated(t)
        skipped = wall - datetime.fromtimestamp(t - 60)
        return skipped > timedelta(minutes=1) and any(
            self._matches(wall - timedelta(minutes=back))
            for back in range(1, int(skipped.total_seconds() // 60))
        )

    def next_after(self, ts):
        """The first fire strictly after ts (epoch seconds), or None if there is none in 8 years.

        Steps through real minutes and tests the fields against local time, so on a DST
        fall-back a job that runs every hour fires in the repeated hour too, while a job at
        fixed hours fires on the first pass only. On a spring-forward the minutes the clock skips
        count as one fire, at the first real minute after the gap (02:30 fires at 03:00).
        """
        t = int(ts // 60) * 60 + 60
        limit = ts + 8 * 366 * 86400
        while t <= limit:
            wall = datetime.fromtimestamp(t)
            if self._fires_at(t):
                return float(t)
            if not self._day_matches(wall):
                midnight = local_time(wall.date() + timedelta(days=1), 0, 0)
                t = max(t + 60, int(midnight.timestamp()))
            elif wall.hour not in self._hours:
                t += 900 - t % 900
            else:
                t += 60
        return None


def local_minute(ts):
    """ts as naive local time, cut to the minute: cron expressions are local time, as in the host's timezone."""
    return datetime.fromtimestamp(ts).replace(second=0, microsecond=0)


def local_time(day, hour, minute):
    return datetime(day.year, day.month, day.day, hour, minute)


class Heartbeat:
    """The Manager Monitor's heartbeat: the mtime of a file it touches."""

    def __init__(self, path):
        self._path = path

    def read(self):
        """(seconds since the last touch or None without a file, whether that is stale)."""
        try:
            age = max(0.0, time.time() - os.stat(self._path).st_mtime)
        except OSError:
            return None, True
        return int(age), age > STALE_S


def created_at(text):
    """Epoch seconds of a table row's `created` datetime text, None when it is not one."""
    if not isinstance(text, str):
        return None
    try:
        return datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", text)).timestamp()
    except ValueError:
        return None


class TableError(RuntimeError):
    """schedules.nuon cannot be read."""


@dataclass(frozen=True, eq=False)
class Entry:
    """One row of the schedule table (eq=False: two rows are two entries, whatever they say)."""

    name: str
    cron: Cron
    prompt: str
    target: str = "auto"
    model: str = "haiku"
    budget: int | None = None
    role: str | None = None
    catchup: str = "skip"
    enabled: bool = True
    created: float | None = None

    def next_fire(self, handled):
        """The first fire after `handled`, the time up to which this entry's fires have been dealt with."""
        return self.cron.next_after(handled)

    def message(self):
        head = f"[schedule {self.name}] "
        if self.target == "headless":
            return f"{head}(headless: start a background session, model {self.model}, with this prompt) {self.prompt}"
        return head + self.prompt


class Table:
    """The schedule table file, a Nushell value, read through nu."""

    def __init__(self, path):
        self._path = path

    def load(self):
        """The valid entries (a bad row is skipped with a log line). Raises TableError."""
        if not os.path.exists(self._path):
            return []
        try:
            out = subprocess.run(
                ["nu", "-c", "open $env.SCHEDULER_TABLE | to json"],
                capture_output=True,
                text=True,
                timeout=20,
                env={**os.environ, "SCHEDULER_TABLE": self._path},
                check=True,
            )
            rows = json.loads(out.stdout or "[]") or []
        except (OSError, subprocess.SubprocessError, ValueError) as e:
            raise TableError(f"{type(e).__name__}: {e}"[:200]) from e
        entries = []
        for row in rows:
            try:
                budget = row.get("budget")
                texts = (row["name"], row["cron"], row["prompt"])
                if not all(isinstance(t, str) for t in texts) or not (
                    budget is None or isinstance(budget, int)
                ):
                    raise TypeError("name, cron and prompt are text, budget a number")
                entries.append(
                    Entry(
                        name=row["name"],
                        cron=Cron(row["cron"]),
                        prompt=row["prompt"],
                        target=row.get("target") or "auto",
                        model=row.get("model") or "haiku",
                        budget=budget,
                        role=(
                            row.get("role")
                            if isinstance(row.get("role"), str)
                            else None
                        ),
                        catchup=row.get("catchup") or "skip",
                        enabled=row.get("enabled") is not False,
                        created=created_at(row.get("created")),
                    )
                )
            except (KeyError, TypeError, CronError) as e:
                log(f"skipping a table row: {type(e).__name__}: {e}")
        return entries


class ForecastError(RuntimeError):
    """The forecast is unavailable or not what usage-db serves."""


class Forecast:
    """usage-db's forecast.json, cached for a few minutes."""

    def __init__(self, url):
        self._url, self._data, self._at = url, None, 0.0

    def get(self, max_age=None):
        """The forecast no older than max_age real seconds (default FORECAST_TTL_S, 0: fetch now). Raises ForecastError."""
        max_age = FORECAST_TTL_S if max_age is None else max_age
        if self._data is not None and time.time() - self._at < max_age:
            return self._data
        try:
            with urllib.request.urlopen(self._url, timeout=3) as r:
                data = json.loads(r.read())
            data["five_hour"]["resets_at"]
        except (OSError, ValueError, KeyError, TypeError) as e:
            raise ForecastError(f"{type(e).__name__}: {e}"[:160]) from e
        self._data, self._at = data, time.time()
        return data


def role_state(role):
    """The role's spend state from claude-usage (ok, quiet, over, n/a); ok when it cannot be read."""
    script = os.environ.get("CLAUDE_USAGE") or os.path.expanduser(
        "~/claude/_tools/homun/bin/claude-usage"
    )
    try:
        out = subprocess.run(
            ["nu", script, "db", "budgets", "json"],
            capture_output=True,
            text=True,
            timeout=20,
            check=True,
        )
        rows = json.loads(out.stdout)
        return next((r["state"] for r in rows if r["role"] == role), "ok")
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
        return "ok"


def budget_line():
    """claude-usage's one budgets line (quiet or over roles, else "budgets ok"); empty when it cannot run."""
    # The installed copy lives in ~/claude/.services/scheduler, so the repo's bin is found by its worktree path
    script = os.environ.get("CLAUDE_USAGE") or os.path.expanduser(
        "~/claude/_tools/homun/bin/claude-usage"
    )
    try:
        out = subprocess.run(
            ["nu", script, "db", "budgets", "alert"],
            capture_output=True,
            text=True,
            timeout=20,
            check=True,
        )
        return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def burn_message(name, points, slots):
    window, minutes = ("7d", 75) if name == "burn-7d" else ("5h", 50)
    return (
        f"{name}: about {minutes} minutes to the {window} reset: pick items from "
        f"`tracker list tag burn` by their properties, within {points} points and {slots} slots"
    )


def open_message(slots, left):
    return (
        f"window-open: {slots} agent slots available, {left}% of the 7d budget projected unused; "
        "start queued issue work per your usual rules"
    )


class ResetAlarms:
    """The forecast alarms of every reset seen (5h: burn-5h and window-open, 7d: burn-7d), keyed by the
    reset's epoch: each is decided once, when its window's reset is first seen."""

    def __init__(self, resets=None):
        self._resets = {
            int(k): {
                ("burn-5h" if n == "leftover-burn" else n): at for n, at in v.items()
            }
            for k, v in (resets or {}).items()
        }

    def to_dict(self):
        return {str(k): v for k, v in self._resets.items()}

    def observe(self, resets_at, now, window="5h"):
        """Learn a reset of `window` from the forecast; a burn alarm is planned only if there is time for it."""
        reset = int(resets_at)
        if reset <= now:
            return
        key = next((k for k in self._resets if abs(reset - k) < SAME_RESET_S), reset)
        plan = self._resets.setdefault(key, {})
        if any(name in plan for name in WINDOW_ALARMS[window]):
            return
        if window == "7d":
            far = key - now > BURN7_MIN_AWAY_S
            plan["burn-7d"] = key - BURN7_BEFORE_S if far else None
        else:
            far = key - now > BURN_MIN_AWAY_S
            plan["burn-5h"] = key - BURN_BEFORE_S if far else None
            plan["window-open"] = key + OPEN_AFTER_S
        for k in [k for k in self._resets if k < now - 86400]:
            del self._resets[k]

    def pending(self):
        """[(name, at, reset)] not yet fired, soonest first."""
        found = [
            (name, at, reset)
            for reset, plan in self._resets.items()
            for name, at in plan.items()
            if at is not None
        ]
        return sorted(found, key=lambda x: x[1])

    def finish(self, name, reset):
        self._resets[reset][name] = None


class StateFile:
    """What survives a restart: the time up to which the service was running and the planned resets."""

    def __init__(self, path):
        self._path = path

    def load(self):
        try:
            with open(self._path) as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def save(self, state):
        tmp = f"{self._path}.tmp"
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, self._path)


class Bus:
    """A fire into the bus inbox of the Manager through `homun-msg send`; a failure is logged, not raised.

    The events file stays as a log of fires; nothing relays it to the session.
    """

    def __init__(self, to="manager", cmd="homun-msg"):
        self._to, self._cmd = to, cmd

    def send(self, alarm, msg):
        try:
            subprocess.run(
                [self._cmd, "send", self._to, alarm, msg],
                check=True,
                capture_output=True,
                timeout=10,
            )
        except (OSError, subprocess.SubprocessError) as e:
            log(f"bus send {alarm} failed: {e}")


class Ledger:
    """Where a fire is written: the bus inbox, the events file, the history and an events row in usage.sqlite."""

    def __init__(self, events, history, db, bus=None):
        self._events, self._history, self._db = events, history, db
        self._bus = bus

    def record(self, ts, alarm, msg, missed, listener_age, manual):
        line = (
            json.dumps({"ts": ts, "alarm": alarm, "msg": msg}, separators=(",", ":"))
            + "\n"
        ).encode()
        with open(self._events, "ab") as f:  # one write, O_APPEND
            f.write(line)
        if self._bus:
            self._bus.send(alarm, msg)
        rec = {
            "ts": ts,
            "name": alarm,
            "msg": msg,
            "missed": missed,
            "listener_age_s": listener_age,
            "manual": manual,
        }
        try:
            with open(self._history, "a") as f:
                f.write(json.dumps(rec, separators=(",", ":")) + "\n")
        except (
            OSError
        ) as e:  # the events line is out: a lost record must not stop the pass
            log(f"history record not written: {e}")
        self._insert_row(ts, "missed" if missed else "fire", alarm)

    def _insert_row(self, ts, kind, detail):
        """The row is a bonus on top of the two files: its failure is logged, not raised."""
        if not os.path.exists(self._db):
            log(f"no usage db at {self._db}, no events row")
            return
        ddl = "create table if not exists events (ts integer not null, source text, kind text, detail text, session_id text)"
        try:
            con = sqlite3.connect(self._db, timeout=2)
            try:
                con.execute(ddl)
                con.execute(
                    "insert into events (ts, source, kind, detail, session_id) values (?, 'scheduler', ?, ?, null)",
                    (ts, kind, detail),
                )
                con.commit()
            finally:
                con.close()
        except sqlite3.Error as e:
            log(f"events row not written: {e}")


class History:
    """The history file, read back for the page."""

    def __init__(self, path):
        self._path = path

    def recent(self, n=50):
        """The last n history records, newest first."""
        try:
            with open(self._path, "rb") as f:
                f.seek(0, 2)
                f.seek(max(0, f.tell() - 65536))
                lines = f.read().decode(errors="replace").splitlines()
        except OSError:
            return []
        records = []
        for line in lines[-n:]:
            try:
                records.append(json.loads(line))
            except ValueError:
                pass
        return records[::-1]


class Book:
    """What the Scheduler knows, for the Report to read: the Scheduler writes it, and only under `lock`."""

    def __init__(self, saved):
        self.seen = saved.get("seen")  # the time the service was last running
        self.resets = ResetAlarms(saved.get("resets"))
        self.entries = []
        self.handled = {}  # Entry -> time up to which its fires were dealt with
        self.table_error = None
        self.forecast_error = None
        self.lock = threading.Lock()


class UnknownAlarm(LookupError):
    """A fire on request was asked for an alarm or table entry that does not exist."""


class Scheduler:
    """Decides what is due, fires it, and says when to look again."""

    def __init__(self, clock, heartbeat, table, forecast, ledger, state, book):
        self._clock, self._heartbeat, self._table = clock, heartbeat, table
        self._forecast, self._ledger, self._state = forecast, ledger, state
        self._book = book
        self._first_load = True
        self._busy = (
            threading.RLock()
        )  # one action at a time; slow fetches happen here, not under book.lock

    # -- loading
    def reload(self):
        """Re-read the table. Enabled entries with an unchanged cron keep their `handled` time; new, changed and
        just re-enabled ones start now (no replay of what a disabled entry missed), or, with catchup once at the
        first load, at the time the service was last seen (one fire replayed).
        """
        with self._busy:
            try:
                fresh = self._table.load()
            except TableError as e:
                with self._book.lock:
                    self._book.table_error = str(e)
                log(f"table not read, keeping the old one: {e}")
                return
            now = self._clock.now()
            old = {e.name: e for e in self._book.entries}
            handled = {}
            for e in fresh:
                kept = old.get(e.name)
                if kept and kept.cron.expr == e.cron.expr and kept.enabled:
                    handled[e] = self._book.handled[kept]
                elif self._first_load and self._book.seen and e.catchup == "once":
                    handled[e] = min(self._book.seen, now)
                else:
                    if self._first_load and self._book.seen:
                        missed = e.next_fire(self._book.seen)
                        if e.enabled and missed is not None and missed <= now:
                            log(
                                f"schedule {e.name} skipped: service was down at its fire time, catchup skip"
                            )
                    handled[e] = now
            with self._book.lock:
                self._book.table_error = None
                self._book.entries, self._book.handled = fresh, handled
            self._first_load = False
            log(f"table loaded: {len(fresh)} schedules")

    def _observe_forecast(self):
        try:
            fc = self._forecast.get()
        except ForecastError as e:
            with self._book.lock:
                self._book.forecast_error = str(e)
            return
        with self._book.lock:
            self._book.forecast_error = None
            for window, key in (("5h", "five_hour"), ("7d", "seven_day")):
                reset = fc[key]["resets_at"]  # null before the first usage sample
                if reset is not None:
                    self._book.resets.observe(reset, self._clock.now(), window)

    # -- firing
    def _deliver(self, name, msg, manual=False):
        age, missed = self._heartbeat.read()
        self._ledger.record(int(self._clock.now()), name, msg, missed, age, manual)
        log(
            f"{'MISSED ' if missed else ''}fired {name}{' (manual)' if manual else ''}: {msg}"
        )

    def _fresh_forecast(self):
        """A forecast fetched now, or None (the error is kept for the health data)."""
        try:
            return self._forecast.get(0)
        except ForecastError as e:
            with self._book.lock:
                self._book.forecast_error = str(e)
            return None

    @staticmethod
    def _alarm_message(name, fc):
        """The message of a forecast alarm; None when the forecast has no slots for window-open."""
        if name in ("burn-5h", "burn-7d"):
            burn = (fc or {}).get("burn") or {}
            return burn_message(name, burn.get("points", "?"), burn.get("slots", "?"))
        slots = (fc or {}).get("slots")
        if slots is None:
            return None
        projected = fc.get("seven_day", {}).get("projected_at_reset")
        return open_message(
            slots, "?" if projected is None else round(max(0, 100 - projected))
        )

    def _due_alarm_message(self, name):
        """The message of a due forecast alarm; None when it must not be sent (window-open needs a free slot,
        a burn alarm a burn budget of >= 1 point, burn-7d a week projected under BURN7_UNDER).
        """
        fc = self._fresh_forecast() or {}
        if name == "window-open" and (fc.get("slots") or 0) < 1:
            return None
        if name.startswith("burn-") and ((fc.get("burn") or {}).get("points") or 0) < 1:
            return None
        projected = fc.get("seven_day", {}).get("projected_at_reset")
        if name == "burn-7d" and (projected is None or projected >= BURN7_UNDER):
            return None
        message = self._alarm_message(name, fc)
        if message and name in ("burn-5h", "window-open") and (line := budget_line()):
            message += f"; {line}"
        return message

    def _within_budget(self, entry):
        if entry.budget is None:
            return True
        try:
            left = 100 - self._forecast.get(60)["five_hour"]["used"]
        except (ForecastError, KeyError, TypeError):
            return True
        return left >= entry.budget

    def run_due(self):
        """Fire everything due now, however late (a table entry once, whatever it missed)."""
        with self._busy:
            self._observe_forecast()
            now = self._clock.now()
            for e in self._book.entries:
                nxt = e.next_fire(self._book.handled[e]) if e.enabled else None
                if nxt is None or nxt > now:
                    continue
                with self._book.lock:
                    self._book.handled[e] = now
                state = role_state(e.role) if e.role else "ok"
                if state in ("quiet", "over"):
                    log(
                        f"schedule {e.name} skipped: role {e.role} is {state} on its daily budget"
                    )
                elif self._within_budget(e):
                    self._deliver(e.name, e.message())
                else:
                    log(f"schedule {e.name} skipped: over its budget limit {e.budget}%")
            for name, at, reset in self._book.resets.pending():
                if at > now:
                    break
                with self._book.lock:
                    self._book.resets.finish(name, reset)
                msg = None if now - at > LATE_S else self._due_alarm_message(name)
                if msg is None:
                    log(f"{name} for reset {reset} not sent")
                else:
                    self._deliver(name, msg)
            self._save()

    def fire_alarm(self, name):
        """Fire a forecast alarm on request, ignoring its time and conditions; returns the message."""
        with self._busy:
            if name not in ALARMS:
                raise UnknownAlarm(f"alarm/{name}")
            msg = self._alarm_message(name, self._fresh_forecast())
            if msg is None:
                raise ForecastError("no forecast available")
            self._deliver(name, msg, manual=True)
            self._save()
            return msg

    def fire_table(self, name):
        """Fire a table entry on request, ignoring its time, enabled flag and budget; returns the message."""
        with self._busy:
            entry = next((e for e in self._book.entries if e.name == name), None)
            if entry is None:
                raise UnknownAlarm(f"table/{name}")
            msg = entry.message()
            self._deliver(name, msg, manual=True)
            self._save()
            return msg

    def _save(self):
        try:
            self._state.save(
                {"seen": int(self._clock.now()), "resets": self._book.resets.to_dict()}
            )
        except OSError as e:
            log(f"state not saved: {e}")

    def sleep_seconds(self):
        """Real seconds until the nearest fire, at most TICK_S."""
        with self._busy:
            times = [
                e.next_fire(self._book.handled[e])
                for e in self._book.entries
                if e.enabled
            ]
            times += [at for _, at, _ in self._book.resets.pending()]
            soonest = min((t for t in times if t is not None), default=None)
            if soonest is None:
                return TICK_S
            return min(
                TICK_S, max(0.0, self._clock.real_seconds(soonest - self._clock.now()))
            )


class Report:
    """Read-only: what the page and the JSON endpoints show."""

    def __init__(self, clock, heartbeat, history, book):
        self._clock, self._heartbeat, self._history, self._book = (
            clock,
            heartbeat,
            history,
            book,
        )

    def next(self):
        """The clock and every alarm and table entry with its next fire, soonest first, undated ones last."""
        book = self._book
        with book.lock:
            now = self._clock.now()
            pending = book.resets.pending()
            rows = []
            for name in ALARMS:
                nxt = next(((at, reset) for n, at, reset in pending if n == name), None)
                at, detail = (
                    (None, "none planned")
                    if nxt is None
                    else (nxt[0], f"reset {nxt[1]}")
                )
                rows.append(
                    {
                        "name": name,
                        "kind": "alarm",
                        "enabled": True,
                        "at": at,
                        "detail": detail,
                    }
                )
            for e in book.entries:
                rows.append(
                    {
                        "name": e.name,
                        "kind": "table",
                        "enabled": e.enabled,
                        "at": e.next_fire(book.handled[e]) if e.enabled else None,
                        "detail": f"{e.cron.expr} ({e.target})",
                    }
                )
        for r in rows:
            r["at"] = None if r["at"] is None else int(r["at"])
            r["in_s"] = None if r["at"] is None else int(r["at"] - now)
        rows.sort(key=lambda r: (r["at"] is None, r["at"] or 0))
        return {"now": int(now), "alarms": rows}

    def health(self):
        age, stale = self._heartbeat.read()
        with self._book.lock:
            return {
                "ok": True,
                "now": int(self._clock.now()),
                "uptime_s": int(time.time() - STARTED),
                "listener_age_s": age,
                "listener_stale": stale,
                "schedules": len(self._book.entries),
                "table_error": self._book.table_error,
                "forecast_error": self._book.forecast_error,
            }

    def recent(self):
        """The last 50 history records, newest first."""
        return self._history.recent(50)


class Agenda:
    """The upcoming fires as org text for org-agenda: table entries expanded to the horizon, the planned alarms and
    the 5h and 7d resets. Read-only, from the Book and the (cached) forecast."""

    MAX_PER_ENTRY = 200

    def __init__(self, clock, forecast, book):
        self._clock, self._forecast, self._book = clock, forecast, book

    def _fires(self, days):
        """([(name, epoch)] within `days`, soonest first, the table error)."""
        now = self._clock.now()
        horizon = now + days * 86400
        with self._book.lock:
            pending = self._book.resets.pending()
            fires = {(name, int(at)) for name, at, _ in pending}
            fires |= {("5h-reset", int(reset)) for _, _, reset in pending}
            error = self._book.table_error
            for e in self._book.entries:
                at = self._book.handled[e] if e.enabled else None
                for _ in range(self.MAX_PER_ENTRY if e.enabled else 0):
                    at = e.cron.next_after(at)
                    if at is None or at > horizon:
                        break
                    fires.add((e.name, int(at)))
        try:
            reset7 = self._forecast.get()["seven_day"]["resets_at"]
        except (ForecastError, KeyError, TypeError):
            reset7 = None  # the forecast is down or has no 7d window yet
        if reset7 is not None and now < reset7:
            fires.add(("7d-reset", int(reset7)))
        return sorted((f for f in fires if f[1] <= horizon), key=lambda f: f[1]), error

    def render(self, days):
        fires, error = self._fires(days)
        fetched = datetime.now().astimezone().isoformat(timespec="seconds")
        lines = ["#+TITLE: scheduler", f"# fetched {fetched}"]
        if error:
            lines.append(f"# table error: {error}")
        for name, at in fires:
            stamp = time.strftime("<%Y-%m-%d %a %H:%M>", time.localtime(at))
            lines += [
                f"* {name} :sched:",
                ":PROPERTIES:",
                f":ID: {name}-{at}",
                ":END:",
                stamp,
            ]
        return "\n".join(lines) + "\n"


def repeater(expr):
    """The org repeater that repeats a simple cron exactly, else "" (the cron stays in a property)."""
    minute, hour, dom, month, dow = expr.split()
    if not minute.isdigit() or (dom, month) != ("*", "*"):
        return ""
    if hour == "*" and dow == "*":
        return " +1h"
    if hour.isdigit() and dow == "*":
        return " +1d"
    if hour.isdigit() and dow.isdigit():
        return " +1w"
    return ""


class ScheduleFile:
    """schedule.org: one SCHEDULED heading per enabled table entry (its next fire, with a repeater when the cron
    is simple), the planned alarms and the 5h and 7d resets. Rewritten, atomically, only when the text changed.
    """

    def __init__(self, path, clock, forecast, book):
        self._path, self._clock, self._forecast, self._book = (
            path,
            clock,
            forecast,
            book,
        )
        self._last = None

    @staticmethod
    def _heading(name, tag, at, rep="", cron=None):
        stamp = time.strftime("%Y-%m-%d %a %H:%M", time.localtime(at))
        lines = [f"* {name} :{tag}:", f"SCHEDULED: <{stamp}{rep}>"]
        if cron:
            lines += [":PROPERTIES:", f":CRON: {cron}", ":END:"]
        return lines

    def render(self):
        now = self._clock.now()
        lines = ["#+TITLE: schedule"]
        with self._book.lock:
            if self._book.table_error:
                lines.append(f"# table error: {self._book.table_error}")
            for e in self._book.entries:
                at = e.next_fire(self._book.handled[e]) if e.enabled else None
                if at is not None:
                    lines += self._heading(
                        e.name, "sched", at, repeater(e.cron.expr), e.cron.expr
                    )
            for name, at, _ in self._book.resets.pending():
                lines += self._heading(name, "alarm", at)
        try:
            data = self._forecast.get()
            resets = [
                ("5h-reset", data["five_hour"]["resets_at"]),
                ("7d-reset", data["seven_day"]["resets_at"]),
            ]
        except (ForecastError, KeyError, TypeError):
            resets = []  # the forecast is down or has no windows yet
        for name, at in resets:
            if at is not None and at > now:
                lines += self._heading(name, "reset", at)
        return "\n".join(lines) + "\n"

    def write(self):
        text = self.render()
        if text == self._last:
            return
        tmp = f"{self._path}.tmp"
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, self._path)
        self._last = text


class AgendaFile(ScheduleFile):
    """agenda.org beside schedule.org: the 14-day agenda Emacs in another container reads instead of the HTTP route."""

    def __init__(self, path, agenda):
        self._path, self._agenda, self._last = path, agenda, None

    def render(self):
        return self._agenda.render(14)


# ---- HTTP: only renders ---------------------------------------------------------------------------------------

CSS = """:root{color-scheme:light dark;--bg:#fff;--fg:#1d2024;--mut:#6a717a;--line:#d8dce1;--bad:#c0392b;--ok:#1e8449}
@media(prefers-color-scheme:dark){:root{--bg:#16181b;--fg:#dde1e6;--mut:#8a929c;--line:#31363c;--bad:#ff6b5b;--ok:#4fc77d}}
body{background:var(--bg);color:var(--fg);font:15px/1.4 system-ui,sans-serif;max-width:60rem;margin:1.5rem auto;padding:0 1rem}
h1{font-size:1.4rem}h2{font-size:1.05rem;margin:1.5rem 0 .4rem}table{border-collapse:collapse;width:100%}
td,th{text-align:left;padding:.25rem .5rem;border-bottom:1px solid var(--line);vertical-align:top}
.mut{color:var(--mut)}.bad{color:var(--bad)}.ok{color:var(--ok)}button{font:inherit;cursor:pointer}td.n{white-space:nowrap}"""

JS = """const f=s=>{s=Math.round(s);const a=Math.abs(s),h=Math.floor(a/3600),m=Math.floor(a%3600/60);
return (s<0?'-':'')+(h?h+'h ':'')+(m||h?m+'m ':'')+(a%60)+'s'};
const t0=Date.now();
setInterval(()=>document.querySelectorAll('[data-in]').forEach(e=>e.textContent=f(+e.dataset.in-(Date.now()-t0)/1000)),1000);
document.querySelectorAll('button[data-fire]').forEach(b=>b.onclick=async()=>{
if(!confirm('Fire '+b.dataset.name+' now?'))return;
const r=await fetch('fire/'+b.dataset.fire,{method:'POST',headers:{'X-Fire':'1'}});
if(!r.ok)alert(await r.text());location.reload()});"""


def clock_text(ts):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts))


def render_page(health, upcoming, recent):
    age = health["listener_age_s"]
    if age is None:
        beat = '<span class="bad">no heartbeat file</span>'
    else:
        word, cls = ("stale", "bad") if health["listener_stale"] else ("alive", "ok")
        beat = f'<span class="{cls}">{word}</span>, touched {age} s ago'
    up = []
    for o in upcoming:
        if not o["enabled"]:
            eta = '<span class="mut">disabled</span>'
        elif o["at"] is None:
            eta = '<span class="mut">none</span>'
        else:
            eta = f'<span data-in="{o["in_s"]}">{o["in_s"]}s</span>'
        when = clock_text(o["at"]) if o["at"] else ""
        name = escape(o["name"])
        up.append(
            f'<tr><td>{name}</td><td class="mut">{escape(o["detail"])}</td><td>{when}</td><td>{eta}</td>'
            f'<td><button data-fire="{o["kind"]}/{name}" data-name="{name}">fire now</button></td></tr>'
        )
    done = []
    for r in recent:
        state = (
            '<span class="bad">missed</span>'
            if r.get("missed")
            else '<span class="ok">fired</span>'
        )
        manual = " (manual)" if r.get("manual") else ""
        done.append(
            f'<tr><td class="n">{clock_text(r.get("ts", 0))}</td><td>{escape(str(r.get("name")))}{manual}</td>'
            f'<td>{state}</td><td class="mut">{escape(str(r.get("msg", "")))}</td></tr>'
        )
    errors = "".join(
        f'<p class="bad">{escape(e)}</p>'
        for e in (health["table_error"], health["forecast_error"])
        if e
    )
    return (
        '<!doctype html><html lang="en"><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        f'<meta http-equiv="refresh" content="60"><title>Scheduler</title><style>{CSS}</style><h1>Scheduler</h1>'
        f'<p>Listener {beat}. Up {health["uptime_s"] // 60} min. <a href="health.json">health</a> '
        f'<a href="next.json">next</a></p>{errors}'
        "<h2>Upcoming</h2><table><tr><th>alarm</th><th>what</th><th>at</th><th>in</th><th></th></tr>"
        f'{"".join(up)}</table><h2>Last 50 fired</h2>'
        "<table><tr><th>time</th><th>alarm</th><th></th><th>message</th></tr>"
        f'{"".join(done) or "<tr><td class=mut>nothing yet</td></tr>"}</table><script>{JS}</script>'
    )


def make_handler(sched, report, agenda):
    class Handler(BaseHTTPRequestHandler):
        def _send(self, code, body, ctype):
            data = body.encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            route = self.path.split("?")[0]
            if route == "/":
                page = render_page(
                    report.health(), report.next()["alarms"], report.recent()
                )
                self._send(200, page, "text/html; charset=utf-8")
            elif route == "/health.json":
                self._send(200, json.dumps(report.health()), "application/json")
            elif route == "/next.json":
                self._send(200, json.dumps(report.next()), "application/json")
            elif route == "/agenda.org":
                query = parse_qs(urlsplit(self.path).query)
                try:
                    days = int(query.get("days", ["14"])[0])
                except ValueError:
                    return self._send(400, "days must be a number", "text/plain")
                text = agenda.render(min(max(days, 1), 90))
                self._send(200, text, "text/plain; charset=utf-8")
            else:
                self._send(404, "not found", "text/plain")

        def do_POST(self):
            parts = self.path.split("?")[0].strip("/").split("/")
            if (
                self.headers.get("X-Fire") != "1"
                or len(parts) != 3
                or parts[0] != "fire"
            ):
                return self._send(
                    400,
                    "POST /fire/alarm|table/<name> with header X-Fire: 1",
                    "text/plain",
                )
            fire = {"alarm": sched.fire_alarm, "table": sched.fire_table}.get(parts[1])
            try:
                if fire is None:
                    raise UnknownAlarm(f"{parts[1]}/{parts[2]}")
                msg = fire(parts[2])
            except UnknownAlarm as e:
                return self._send(404, f"unknown: {e}", "text/plain")
            except ForecastError as e:
                return self._send(502, str(e), "text/plain")
            return self._send(
                200,
                json.dumps({"ok": True, "alarm": parts[2], "msg": msg}),
                "application/json",
            )

        def log_message(self, fmt, *args):
            pass

    return Handler


def main():
    port = (
        int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("PORT") or 8424)
    )
    services = os.environ.get("CLAUDE_SERVICES_DIR") or os.path.expanduser(
        "~/claude/.services"
    )
    state = os.environ.get("SCHEDULER_DIR") or os.path.join(services, "scheduler")
    sched_dir = os.environ.get("CLAUDE_SCHED_DIR") or os.path.join(services, "sched")
    table = os.environ.get("SCHEDULER_TABLE") or os.path.join(
        sched_dir, "schedules.nuon"
    )
    db = os.environ.get("SCHEDULER_DB") or os.path.join(
        services, "usage-db", "usage.sqlite"
    )
    url = (
        os.environ.get("SCHEDULER_FORECAST_URL")
        or "http://127.0.0.1:8420/forecast.json"
    )
    clock = Clock(
        float(os.environ.get("SCHEDULER_NOW") or 0) or None,
        float(os.environ.get("SCHEDULER_SPEED") or 1),
    )
    os.makedirs(state, exist_ok=True)
    history_path = os.path.join(state, "history.jsonl")
    history = History(history_path)
    heartbeat = Heartbeat(HEARTBEAT_PATH)
    statefile = StateFile(os.path.join(state, "state.json"))
    book = Book(statefile.load())
    forecast = Forecast(url)
    events_path = os.path.join(state, "events")
    sched = Scheduler(
        clock,
        heartbeat,
        Table(table),
        forecast,
        Ledger(events_path, history_path, db, Bus()),
        statefile,
        book,
    )
    report = Report(clock, heartbeat, history, book)
    agenda = Agenda(clock, forecast, book)
    schedule_file = ScheduleFile(
        os.environ.get("SCHEDULER_ORG") or os.path.join(state, "schedule.org"),
        clock,
        forecast,
        book,
    )
    agenda_file = AgendaFile(
        os.environ.get("SCHEDULER_AGENDA") or os.path.join(state, "agenda.org"),
        agenda,
    )
    wake, reload = threading.Event(), threading.Event()
    reload.set()

    def on_hup(*_):
        reload.set()
        wake.set()

    signal.signal(signal.SIGHUP, on_hup)
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    server = ThreadingHTTPServer(
        ("127.0.0.1", port), make_handler(sched, report, agenda)
    )
    threading.Thread(target=server.serve_forever, daemon=True).start()
    log(f"listening on 127.0.0.1:{port}, state in {state}")
    while True:
        if reload.is_set():
            reload.clear()
            sched.reload()
        try:
            sched.run_due()
        except OSError as e:
            # the events file or history cannot be written; the fire's time is already handled, so it is lost
            log(f"fire failed: {e}")
        try:
            schedule_file.write()
        except OSError as e:
            log(f"schedule.org not written: {e}")
        try:
            agenda_file.write()
        except OSError as e:
            log(f"agenda.org not written: {e}")
        wake.wait(sched.sleep_seconds() + 0.05)
        wake.clear()


if __name__ == "__main__":
    main()
