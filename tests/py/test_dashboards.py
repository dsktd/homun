"""Run every SQL panel of the Grafana dashboards against a read-only database.

DASH_DB names a copy of usage.sqlite (skipped when absent). Run with
`python3 -m unittest tests/py/test_dashboards.py` (or from tests/py).
"""

import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "container/services/maint"))
import collect

sys.path.insert(0, str(ROOT / "container/services/usage-db"))
import forecast

DASHBOARDS = ROOT / "container/services/graphs/dashboards"
DB = os.environ.get("DASH_DB", "")
DAY_MS = 86_400_000


def import_ddl(*tables):
    """import.nu's own create statements for the tables, so the seed cannot drift."""
    text = (ROOT / "container/services/usage-db/import.nu").read_text()
    found = [
        m.replace("if not exists ", "")
        for table in tables
        for m in re.findall(rf'"(create table if not exists {table} \(.*?\))"', text)
    ]
    assert len(found) == len(tables), found
    return found


class Panels:
    """The SQL targets of the dashboard files, with the macros filled in."""

    def __init__(self, directory, now_ms):
        self.directory = directory
        self.now_ms = now_ms

    def sql(self, text):
        return text.replace("$__from", str(self.now_ms - 7 * DAY_MS)).replace(
            "$__to", str(self.now_ms)
        )

    def all(self):
        for path in sorted(self.directory.glob("*.json")):
            for panel in json.loads(path.read_text())["panels"]:
                for target in panel.get("targets", []):
                    if "queryText" in target:
                        yield path.stem, panel, target


@unittest.skipUnless(DB and Path(DB).exists(), "DASH_DB copy not available")
class DashboardQueries(unittest.TestCase):
    def setUp(self):
        # a copy, since the maint panels need maint_runs rows the live DB may
        # not have yet (collect.py creates the table on the first run)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        copy = Path(tmp.name) / "usage.sqlite"
        shutil.copy(DB, copy)
        seed = sqlite3.connect(copy)
        seed.execute("drop table if exists maint_runs")
        seed.execute(collect.SCHEMA)
        now = int(time.time())
        seed.executemany(
            "insert into maint_runs values (?,?,?,?,?,?,?,?,?,?,?)",
            [
                (
                    now - h * 3600,
                    "demo.git",
                    "auto",
                    40 + h,
                    h % 5 != 0,
                    9,
                    1,
                    2,
                    300,
                    0,
                    7,
                )
                for h in range(48)
            ],
        )
        # a restart within the hour adds a second row for the same repo
        seed.execute(
            "insert into maint_runs select ts/3600*3600, repo, task, duration_ms, ok, "
            "loose, in_pack, packs, size_kib, garbage, refs from maint_runs"
        )
        for table in ("mode_history", "agent_runs", "events"):
            seed.execute(f"drop table if exists {table}")
        for ddl in import_ddl("agent_runs", "events"):
            seed.execute(ddl)
        seed.executemany(
            "insert into agent_runs values (?,?,?,?,?,?,?,?)",
            [
                (
                    f"s{d}{i}",
                    "w",
                    "background",
                    "/x",
                    now - d * 86400 - i,
                    state,
                    now,
                    1,
                )
                for d in range(6)
                for i, state in enumerate(["done", "failed", "stopped", "working"])
            ],
        )
        seed.execute(
            "insert into events values (?, 'scheduler', 'fire', 'window-open', null)",
            (now,),
        )
        seed.commit()
        seed.close()
        for h in range(48):
            forecast.record_mode(
                str(copy),
                now - (48 - h) * 3600,
                ["burn", "normal", "frugal"][h // 8 % 3],
                "normal",
                h % 7 == 0,
                h % 4,
                "r",
                10,
                20,
                50 + h,
            )
        self.con = sqlite3.connect(f"file:{copy}?mode=ro", uri=True)
        self.addCleanup(self.con.close)
        self.panels = Panels(DASHBOARDS, int(time.time() * 1000))

    def run_panel(self, target):
        cursor = self.con.execute(self.panels.sql(target["queryText"]))
        return [d[0] for d in cursor.description], cursor.fetchall()

    def test_loose_objects_take_one_row_per_repo_per_hour(self):
        for name, panel, target in self.panels.all():
            if panel["title"] == "Loose objects and packs":
                _, rows = self.run_panel(target)
                self.assertEqual({(r[1], r[2]) for r in rows}, {(9, 2)})

    def test_raw_and_query_text_agree(self):
        for name, panel, target in self.panels.all():
            with self.subTest(dashboard=name, panel=panel["title"]):
                self.assertEqual(target["queryText"], target["rawQueryText"])

    def test_datasource_is_the_provisioned_one(self):
        for name, panel, target in self.panels.all():
            with self.subTest(dashboard=name, panel=panel["title"]):
                for ds in (panel["datasource"], target["datasource"]):
                    self.assertEqual(ds["uid"], "usage")
                    self.assertEqual(ds["type"], "frser-sqlite-datasource")

    def test_every_query_runs_with_rows_and_the_right_columns(self):
        for name, panel, target in self.panels.all():
            with self.subTest(dashboard=name, panel=panel["title"]):
                columns, rows = self.run_panel(target)
                self.assertTrue(rows, "no rows over the last 7 days")
                kind = panel["type"]
                if target.get("queryType") == "time series":
                    self.assertEqual(columns[0], "time")
                    self.assertIn("time", target["timeColumns"])
                if kind == "state-timeline":
                    self.assertEqual(len(columns), 2)
                    self.assertTrue(all(isinstance(r[1], str) for r in rows))
                if kind == "piechart":
                    # long (label, value...) or wide (one numeric column per
                    # slice); a null value just draws no slice
                    labelled = isinstance(rows[0][0], str)
                    values = [v for r in rows for v in (r[1:] if labelled else r)]
                    self.assertTrue(values)
                    self.assertTrue(
                        all(v is None or isinstance(v, (int, float)) for v in values)
                    )
                if kind in ("timeseries", "stat", "gauge", "bargauge"):
                    numeric = rows[0][1:] if columns[0] == "time" else rows[0]
                    self.assertTrue(numeric)


if __name__ == "__main__":
    unittest.main()
