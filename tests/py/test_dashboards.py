"""Run every SQL panel of the Grafana dashboards against a read-only database.

DASH_DB names a copy of usage.sqlite (skipped when absent). Run with
`python3 -m unittest tests/py/test_dashboards.py` (or from tests/py).
"""

import json
import os
import sqlite3
import time
import unittest
from pathlib import Path

DASHBOARDS = (
    Path(__file__).resolve().parents[2] / "container/services/graphs/dashboards"
)
DB = os.environ.get("DASH_DB", "")
DAY_MS = 86_400_000


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
        self.con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
        self.addCleanup(self.con.close)
        self.panels = Panels(DASHBOARDS, int(time.time() * 1000))

    def run_panel(self, target):
        cursor = self.con.execute(self.panels.sql(target["queryText"]))
        return [d[0] for d in cursor.description], cursor.fetchall()

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
