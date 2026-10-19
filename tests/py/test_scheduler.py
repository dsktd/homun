"""Tests of container/services/scheduler/serve.py: Cron, ResetAlarms, Table, Agenda, Ledger and History."""

import contextlib
import importlib.util
import io
import json
import os
import shutil
import tempfile
import time
import unittest
from datetime import datetime
from pathlib import Path

SERVE = Path(__file__).resolve().parents[2] / "container/services/scheduler/serve.py"
spec = importlib.util.spec_from_file_location("scheduler_serve", SERVE)
serve = importlib.util.module_from_spec(spec)
spec.loader.exec_module(serve)

HOUR = 3600


def epoch(*parts):
    """Local-time epoch of (year, month, day, hour, minute)."""
    return datetime(*parts).timestamp()  # noqa: DTZ001


class TimezoneCase(unittest.TestCase):
    """A test case that runs in a fixed timezone and a temp dir."""

    tz = "UTC"

    def setUp(self):
        old = os.environ.get("TZ")
        self.addCleanup(self._restore_tz, old)
        os.environ["TZ"] = self.tz
        time.tzset()
        self.tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))  # serve.log

    @staticmethod
    def _restore_tz(old):
        if old is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = old
        time.tzset()


class CronTest(TimezoneCase):
    def next(self, expr, ts):
        return serve.Cron(expr).next_after(ts)

    def test_step(self):
        self.assertEqual(
            self.next("*/15 * * * *", epoch(2026, 10, 1, 10, 7)),
            epoch(2026, 10, 1, 10, 15),
        )

    def test_step_wraps_to_next_hour(self):
        self.assertEqual(
            self.next("*/15 * * * *", epoch(2026, 10, 1, 10, 45)),
            epoch(2026, 10, 1, 11, 0),
        )

    def test_range_with_step(self):
        self.assertEqual(
            self.next("0 9-17/4 * * *", epoch(2026, 10, 1, 9, 30)),
            epoch(2026, 10, 1, 13, 0),
        )

    def test_list(self):
        self.assertEqual(
            self.next("0,30 8 * * *", epoch(2026, 10, 1, 8, 0)),
            epoch(2026, 10, 1, 8, 30),
        )

    def test_strictly_after_a_fire_time(self):
        self.assertEqual(
            self.next("15 10 * * *", epoch(2026, 10, 1, 10, 15)),
            epoch(2026, 10, 2, 10, 15),
        )

    def test_seconds_before_a_fire_time_still_fire_it(self):
        self.assertEqual(
            self.next("15 10 * * *", epoch(2026, 10, 1, 10, 14) + 59.5),
            epoch(2026, 10, 1, 10, 15),
        )

    def test_dom_and_dow_both_restricted_is_or(self):
        # Oct 2 2026 is a Friday, the first of "the 13th or a Friday".
        self.assertEqual(
            self.next("0 0 13 * 5", epoch(2026, 10, 1, 0, 0)),
            epoch(2026, 10, 2, 0, 0),
        )

    def test_dom_and_dow_still_or_on_the_13th(self):
        self.assertEqual(
            self.next("0 0 13 * 5", epoch(2026, 10, 12, 12, 0)),
            epoch(2026, 10, 13, 0, 0),
        )

    def test_only_dow_restricted_is_and(self):
        self.assertEqual(
            self.next("0 0 * * 5", epoch(2026, 10, 3, 0, 0)),
            epoch(2026, 10, 9, 0, 0),
        )

    def test_feb_29_waits_for_a_leap_year(self):
        self.assertEqual(
            self.next("0 0 29 2 *", epoch(2026, 1, 1, 0, 0)),
            epoch(2028, 2, 29, 0, 0),
        )

    def test_sunday_as_0(self):
        # Oct 17 2026 is a Saturday.
        self.assertEqual(
            self.next("0 0 * * 0", epoch(2026, 10, 17, 12, 0)),
            epoch(2026, 10, 18, 0, 0),
        )

    def test_sunday_as_7(self):
        self.assertEqual(
            self.next("0 0 * * 7", epoch(2026, 10, 17, 12, 0)),
            epoch(2026, 10, 18, 0, 0),
        )

    def test_impossible_date_gives_none(self):
        self.assertIsNone(self.next("0 0 31 2 *", epoch(2026, 1, 1, 0, 0)))

    def test_bad_expressions_raise(self):
        for expr in (
            "",
            "* * * *",
            "* * * * * *",
            "60 * * * *",
            "* 24 * * *",
            "* * 0 * *",
            "* * 32 * *",
            "* * * 13 *",
            "* * * * 8",
            "*/0 * * * *",
            "a * * * *",
            "5-1 * * * *",
            "1- * * * *",
            "@daily * * * *",
        ):
            with self.subTest(expr=expr), self.assertRaises(serve.CronError):
                serve.Cron(expr)


@unittest.skipUnless(Path("/usr/share/zoneinfo/America/New_York").exists(), "no tzdata")
class CronDstTest(TimezoneCase):
    tz = "America/New_York"

    def test_daily_noon_across_spring_forward_is_23_hours_later(self):
        start = epoch(2026, 3, 7, 12, 0)
        self.assertEqual(serve.Cron("0 12 * * *").next_after(start), start + 23 * HOUR)

    def test_time_in_the_spring_forward_gap_fires_once_that_night(self):
        start = epoch(2026, 3, 7, 12, 0)
        fire = serve.Cron("30 2 * * *").next_after(start)
        self.assertLess(fire - start, 24 * HOUR)

    def test_gap_time_is_not_repeated_the_next_minute(self):
        cron = serve.Cron("30 2 * * *")
        fire = cron.next_after(epoch(2026, 3, 7, 12, 0))
        self.assertGreater(cron.next_after(fire) - fire, 20 * HOUR)

    def test_fall_back_ambiguous_time_fires_once(self):
        cron = serve.Cron("30 1 * * *")
        first = cron.next_after(epoch(2026, 10, 31, 12, 0))
        self.assertGreater(cron.next_after(first) - first, 20 * HOUR)

    def test_fall_back_day_has_25_hours(self):
        start = epoch(2026, 10, 31, 12, 0)
        self.assertEqual(serve.Cron("0 12 * * *").next_after(start), start + 25 * HOUR)

    def test_hourly_fires_in_the_repeated_hour(self):
        # 01:30 EDT is followed by 01:00 EST 30 minutes later; cron fires hourly jobs there.
        first_pass = epoch(2026, 11, 1, 1, 30)
        fire = serve.Cron("0 * * * *").next_after(first_pass)
        self.assertEqual(fire - first_pass, 30 * 60)


class ResetAlarmsTest(unittest.TestCase):
    NOW = 1_000_000

    def planned(self, alarms):
        return {name: at for name, at, _ in alarms.pending()}

    def test_far_reset_plans_both_alarms(self):
        alarms = serve.ResetAlarms()
        reset = self.NOW + 2 * HOUR
        alarms.observe(reset, self.NOW)
        self.assertEqual(
            self.planned(alarms),
            {"leftover-burn": reset - 3000, "window-open": reset + 300},
        )

    def test_reset_under_55_minutes_away_skips_leftover_burn(self):
        alarms = serve.ResetAlarms()
        reset = self.NOW + 54 * 60
        alarms.observe(reset, self.NOW)
        self.assertEqual(self.planned(alarms), {"window-open": reset + 300})

    def test_reset_exactly_55_minutes_away_skips_leftover_burn(self):
        alarms = serve.ResetAlarms()
        alarms.observe(self.NOW + 3300, self.NOW)
        self.assertNotIn("leftover-burn", self.planned(alarms))

    def test_past_reset_is_ignored(self):
        alarms = serve.ResetAlarms()
        alarms.observe(self.NOW - 1, self.NOW)
        self.assertEqual(alarms.pending(), [])

    def test_the_same_reset_seen_again_is_not_replanned(self):
        alarms = serve.ResetAlarms()
        reset = self.NOW + 2 * HOUR
        alarms.observe(reset, self.NOW)
        alarms.finish("leftover-burn", reset)
        alarms.observe(reset + 5, self.NOW + 60)
        self.assertEqual(list(self.planned(alarms)), ["window-open"])

    def test_survives_a_round_trip_through_the_state_file(self):
        alarms = serve.ResetAlarms()
        alarms.observe(self.NOW + 2 * HOUR, self.NOW)
        copy = serve.ResetAlarms(json.loads(json.dumps(alarms.to_dict())))
        self.assertEqual(copy.pending(), alarms.pending())

    def test_old_resets_are_forgotten(self):
        alarms = serve.ResetAlarms()
        alarms.observe(self.NOW + 2 * HOUR, self.NOW)
        later = self.NOW + 2 * 86400
        alarms.observe(later + 2 * HOUR, later)
        self.assertEqual({r for _, _, r in alarms.pending()}, {later + 2 * HOUR})


class FakeClock:
    def __init__(self, now):
        self.t = now

    def now(self):
        return self.t

    def real_seconds(self, clock_seconds):
        return clock_seconds


class FakeForecast:
    def __init__(self, reset, slots=2, used=40):
        self.data = {
            "five_hour": {"resets_at": reset, "used": used},
            "seven_day": {"resets_at": reset + 86400, "projected_at_reset": 60},
            "slots": slots,
        }

    def get(self, max_age=None):
        return self.data


class FakeTable:
    def load(self):
        return []


class SchedulerTest(TimezoneCase):
    """Forecast alarms through Scheduler.run_due, with files in a temp dir."""

    NOW = 2_000_000
    RESET = NOW + 2 * HOUR

    def make(self, clock, forecast):
        """A Scheduler over self.tmp; the state file carries over between calls."""
        state = serve.StateFile(str(self.tmp / "state.json"))
        book = serve.Book(state.load())
        sched = serve.Scheduler(
            clock,
            serve.Heartbeat(str(self.tmp / "listener")),
            FakeTable(),
            forecast,
            serve.Ledger(
                str(self.tmp / "events"),
                str(self.tmp / "history.jsonl"),
                str(self.tmp / "no.sqlite"),
            ),
            state,
            book,
        )
        sched.reload()
        return sched

    def fired(self):
        events = self.tmp / "events"
        if not events.exists():
            return []
        return [json.loads(x)["alarm"] for x in events.read_text().splitlines()]

    def test_window_open_is_sent_with_a_slot(self):
        clock = FakeClock(self.NOW)
        sched = self.make(clock, FakeForecast(self.RESET, slots=1))
        sched.run_due()
        clock.t = self.RESET + 301
        sched.run_due()
        self.assertEqual(self.fired(), ["window-open"])

    def test_window_open_is_not_sent_without_slots(self):
        clock = FakeClock(self.NOW)
        sched = self.make(clock, FakeForecast(self.RESET, slots=0))
        sched.run_due()
        clock.t = self.RESET + 301
        sched.run_due()
        self.assertEqual(self.fired(), [])

    def test_leftover_burn_fires_50_minutes_before_the_reset(self):
        clock = FakeClock(self.NOW)
        sched = self.make(clock, FakeForecast(self.RESET))
        sched.run_due()
        clock.t = self.RESET - 3000 + 1
        sched.run_due()
        self.assertEqual(self.fired(), ["leftover-burn"])

    def test_a_restart_does_not_fire_an_alarm_twice(self):
        clock = FakeClock(self.NOW)
        forecast = FakeForecast(self.RESET)
        sched = self.make(clock, forecast)
        sched.run_due()
        clock.t = self.RESET - 3000 + 1
        sched.run_due()
        again = self.make(clock, forecast)
        clock.t += 30
        again.run_due()
        self.assertEqual(self.fired(), ["leftover-burn"])

    def test_late_restart_drops_a_leftover_burn_after_10_minutes(self):
        clock = FakeClock(self.NOW)
        forecast = FakeForecast(self.RESET)
        self.make(clock, forecast).run_due()
        clock.t = self.RESET - 3000 + 601
        self.make(clock, forecast).run_due()
        self.assertEqual(self.fired(), [])

    def test_restart_within_10_minutes_still_fires_the_leftover_burn(self):
        clock = FakeClock(self.NOW)
        forecast = FakeForecast(self.RESET)
        self.make(clock, forecast).run_due()
        clock.t = self.RESET - 3000 + 599
        self.make(clock, forecast).run_due()
        self.assertEqual(self.fired(), ["leftover-burn"])


class TableTest(TimezoneCase):
    @unittest.skipUnless(shutil.which("nu"), "needs nu")
    def test_load_skips_malformed_rows(self):
        path = self.tmp / "schedules.nuon"
        path.write_text(
            "[\n"
            '{name: "good", cron: "0 9 * * *", prompt: "hi", budget: 20},\n'
            '{name: "bad-cron", cron: "99 * * * *", prompt: "x"},\n'
            '{name: "no-prompt", cron: "0 9 * * *"},\n'
            '{name: "bad-budget", cron: "0 9 * * *", prompt: "x", budget: "lots"},\n'
            '{name: "off", cron: "5 4 * * *", prompt: "y", enabled: false},\n'
            "]\n"
        )
        entries = serve.Table(str(path)).load()
        self.assertEqual(
            [(e.name, e.enabled) for e in entries], [("good", True), ("off", False)]
        )

    def test_missing_file_is_an_empty_table(self):
        self.assertEqual(serve.Table(str(self.tmp / "none")).load(), [])


class ScheduleFileTest(TimezoneCase):
    NOW = epoch(2026, 10, 17, 12, 0)

    def make(self, entries, forecast=None):
        book = serve.Book({})
        book.entries = list(entries)
        book.handled = {e: self.NOW for e in book.entries}
        self.path = self.tmp / "schedule.org"
        return serve.ScheduleFile(
            str(self.path),
            FakeClock(self.NOW),
            forecast or FakeForecast(self.NOW + HOUR),
            book,
        )

    @staticmethod
    def entry(name, cron, enabled=True):
        return serve.Entry(name, serve.Cron(cron), "do it", enabled=enabled)

    def test_repeaters(self):
        self.assertEqual(serve.repeater("0 9 * * *"), " +1d")
        self.assertEqual(serve.repeater("0 9 * * 1"), " +1w")
        self.assertEqual(serve.repeater("30 * * * *"), " +1h")
        self.assertEqual(serve.repeater("*/5 * * * *"), "")
        self.assertEqual(serve.repeater("0 9 1 * *"), "")

    def test_entry_and_resets(self):
        out = self.make([self.entry("daily", "0 9 * * *")])
        out.write()
        text = self.path.read_text()
        self.assertIn(
            "* daily :sched:\nSCHEDULED: <2026-10-18 Sun 09:00 +1d>\n"
            ":PROPERTIES:\n:CRON: 0 9 * * *\n:END:\n",
            text,
        )
        self.assertIn("* 5h-reset :reset:\nSCHEDULED: <2026-10-17 Sat 13:00>", text)
        self.assertIn("* 7d-reset :reset:", text)

    def test_disabled_entry_is_left_out(self):
        out = self.make([self.entry("off", "0 9 * * *", enabled=False)])
        self.assertNotIn("off", out.render())

    def test_missing_forecast_skips_resets(self):
        forecast = FakeForecast(self.NOW + HOUR)
        forecast.data = {}
        text = self.make([], forecast).render()
        self.assertNotIn("reset", text)

    def test_unchanged_text_is_not_rewritten(self):
        out = self.make([self.entry("daily", "0 9 * * *")])
        out.write()
        self.path.unlink()
        out.write()
        self.assertFalse(self.path.exists())


class AgendaTest(TimezoneCase):
    NOW = epoch(2026, 10, 17, 12, 0)

    def make(self, entries=(), forecast=None):
        book = serve.Book({})
        book.entries = list(entries)
        book.handled = {e: self.NOW for e in book.entries}
        return book, serve.Agenda(
            FakeClock(self.NOW), forecast or FakeForecast(self.NOW + HOUR), book
        )

    @staticmethod
    def entry(name, cron):
        return serve.Entry(name, serve.Cron(cron), "do it")

    def test_daily_cron_is_one_org_entry_per_day(self):
        forecast = FakeForecast(self.NOW + HOUR)
        forecast.data["seven_day"]["resets_at"] = None
        _, agenda = self.make([self.entry("daily", "0 9 * * *")], forecast)
        text = agenda.render(3)
        self.assertEqual(
            [x for x in text.splitlines() if x.startswith("<")],
            [
                "<2026-10-18 Sun 09:00>",
                "<2026-10-19 Mon 09:00>",
                "<2026-10-20 Tue 09:00>",
            ],
        )

    def test_entry_has_tag_and_id(self):
        _, agenda = self.make([self.entry("daily", "0 9 * * *")])
        at = int(epoch(2026, 10, 18, 9, 0))
        self.assertIn(
            f"* daily :sched:\n:PROPERTIES:\n:ID: daily-{at}\n:END:\n<2026-10-18 Sun 09:00>\n",
            agenda.render(1),
        )

    def test_planned_alarms_and_resets_are_listed(self):
        reset = int(self.NOW + 2 * HOUR)
        book, agenda = self.make(forecast=FakeForecast(reset))
        book.resets.observe(reset, self.NOW)
        names = [x for x in agenda.render(2).splitlines() if x.startswith("* ")]
        self.assertEqual(
            sorted(names),
            [
                "* 5h-reset :sched:",
                "* 7d-reset :sched:",
                "* leftover-burn :sched:",
                "* window-open :sched:",
            ],
        )

    def test_table_error_is_a_comment(self):
        book, agenda = self.make()
        book.table_error = "boom"
        self.assertIn("# table error: boom\n", agenda.render(1))

    def test_no_error_comment_without_an_error(self):
        _, agenda = self.make()
        self.assertNotIn("table error", agenda.render(1))

    def test_each_entry_is_capped_at_200_fires(self):
        _, agenda = self.make([self.entry("busy", "* * * * *")])
        count = agenda.render(90).count("* busy :sched:")
        self.assertEqual(count, serve.Agenda.MAX_PER_ENTRY)

    def test_disabled_entries_are_skipped(self):
        off = serve.Entry("off", serve.Cron("0 9 * * *"), "x", enabled=False)
        _, agenda = self.make([off])
        self.assertNotIn("* off", agenda.render(3))


class LedgerTest(TimezoneCase):
    def make(self, history=None):
        return serve.Ledger(
            str(self.tmp / "events"),
            str(history or self.tmp / "history.jsonl"),
            str(self.tmp / "no.sqlite"),
        )

    def test_record_appends_one_event_line(self):
        self.make().record(100, "daily", "hello", False, 5, False)
        lines = (self.tmp / "events").read_text().splitlines()
        self.assertEqual(
            [json.loads(x) for x in lines],
            [{"ts": 100, "alarm": "daily", "msg": "hello"}],
        )

    def test_record_appends_one_history_line(self):
        self.make().record(100, "daily", "hello", True, 700, True)
        lines = (self.tmp / "history.jsonl").read_text().splitlines()
        self.assertEqual(
            [json.loads(x) for x in lines],
            [
                {
                    "ts": 100,
                    "name": "daily",
                    "msg": "hello",
                    "missed": True,
                    "listener_age_s": 700,
                    "manual": True,
                }
            ],
        )

    def test_an_unwritable_history_does_not_lose_the_event(self):
        history = self.tmp / "history-is-a-dir"
        history.mkdir()
        self.make(history).record(100, "daily", "hello", False, 5, False)
        self.assertEqual(len((self.tmp / "events").read_text().splitlines()), 1)

    def test_an_events_row_is_inserted_when_the_db_exists(self):
        import sqlite3

        db = self.tmp / "usage.sqlite"
        sqlite3.connect(db).close()
        serve.Ledger(str(self.tmp / "events"), str(self.tmp / "h"), str(db)).record(
            100, "daily", "m", True, None, False
        )
        con = sqlite3.connect(db)
        self.addCleanup(con.close)
        self.assertEqual(
            con.execute("select ts, source, kind, detail from events").fetchall(),
            [(100, "scheduler", "missed", "daily")],
        )


class HistoryTest(TimezoneCase):
    def test_recent_is_newest_first(self):
        path = self.tmp / "h"
        path.write_text('{"n":1}\n{"n":2}\n{"n":3}\n')
        self.assertEqual(serve.History(str(path)).recent(2), [{"n": 3}, {"n": 2}])

    def test_recent_skips_garbage_lines(self):
        path = self.tmp / "h"
        path.write_text('{"n":1}\nnot json\n{"n":3}\n')
        self.assertEqual(serve.History(str(path)).recent(), [{"n": 3}, {"n": 1}])

    def test_recent_without_a_file_is_empty(self):
        self.assertEqual(serve.History(str(self.tmp / "none")).recent(), [])


if __name__ == "__main__":
    unittest.main()
