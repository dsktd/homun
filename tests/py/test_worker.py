"""Tests of bin/claude-worker, with a stub `claude` and every path in a temp dir."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import argparse
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / "bin/claude-worker"
loader = importlib.machinery.SourceFileLoader("claude_worker", str(SCRIPT))
spec = importlib.util.spec_from_loader("claude_worker", loader)
worker = importlib.util.module_from_spec(spec)
loader.exec_module(worker)

PREFIX = "sk-ant" + "-"  # built at run time, so no key-shaped literal sits in the repo
KEY = PREFIX + "api03-thisisthetestkey_123"
AGENT = "---\ndescription: a test agent\nmodel: haiku\n---\nDo the work.\n"


class CapArgTest(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(worker, "DAILY_CAP", 10.0)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_valid_caps(self):
        self.assertEqual(
            [worker.cap_arg(t) for t in ("0.01", "2", "10")], [0.01, 2.0, 10.0]
        )

    def test_invalid_caps_are_refused(self):
        for text in ("nan", "inf", "-inf", "-5", "0", "10.01", "abc", ""):
            with (
                self.subTest(cap=text),
                self.assertRaises(argparse.ArgumentTypeError),
            ):
                worker.cap_arg(text)

    def test_parser_default_cap(self):
        args = worker.parser().parse_args(["run", "n", "a", "w", "p"])
        self.assertEqual(args.cap, worker.DEFAULT_CAP)


class RedactTest(unittest.TestCase):
    def test_exact_key_is_redacted_everywhere(self):
        self.assertEqual(
            worker.redact(f"a {KEY} b {KEY}", KEY), "a [redacted] b [redacted]"
        )

    def test_key_shaped_strings_are_redacted(self):
        self.assertEqual(
            worker.redact(f"x {PREFIX}oat01-AbC_d-9 y", KEY), "x [redacted] y"
        )

    def test_other_text_is_kept(self):
        self.assertEqual(worker.redact("sk-other ant-sk", KEY), "sk-other ant-sk")


class WorkerCase(unittest.TestCase):
    """A temp dir holding the workers dir, a key, an agent, a worktree, a prompt and a stub claude."""

    def setUp(self):
        self.tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.workers = self.tmp / "workers"
        for name, value in {
            "WORKERS": self.workers,
            "KEY_FILE": self.tmp / "api.key",
            "EVENTS": self.tmp / "events",
            "AGENTS": self.tmp / "agents",
            "CLAUDE": str(self.tmp / "claude"),
            "DAILY_CAP": 10.0,
            "START_BALANCE": 50.0,
        }.items():
            self.enterContext(mock.patch.object(worker, name, value))
        worker.KEY_FILE.write_text(KEY + "\n")
        worker.AGENTS.mkdir()
        (worker.AGENTS / "dev.md").write_text(AGENT)
        self.tree = self.tmp / "tree"
        self.tree.mkdir()
        self.prompt = self.tmp / "prompt.txt"
        self.prompt.write_text("go\n")
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))

    def stub(self, body):
        path = self.tmp / "claude"
        path.write_text(f"#!/bin/sh\ncat >/dev/null\n{body}\n")
        path.chmod(0o755)

    def stub_result(self, cost, extra=""):
        out = {
            "result": f"done {KEY}",
            "total_cost_usd": cost,
            "usage": {"input_tokens": 10, "output_tokens": 5},
        }
        self.stub(f"{extra}\ncat <<'JSON'\n{json.dumps(out)}\nJSON")

    def start(self, name="run1", cap="2", agent="dev", quiet=False):
        args = argparse.Namespace(
            name=name,
            agent_type=agent,
            worktree=str(self.tree),
            prompt_file=str(self.prompt),
            model=None,
            cap=worker.cap_arg(cap),
            quiet=quiet,
        )
        return worker.run(args)

    def ledger(self):
        return worker.read_jsonl(self.workers / "ledger.jsonl")

    def remaining(self):
        return worker.read_balance()["remaining_usd"]


class RunNameTest(WorkerCase):
    def test_bad_names_are_refused(self):
        for name in ("", "bad name", "-x", ".x", "a/b", "x.tmp", "y.json", "é"):
            with self.subTest(name=name), self.assertRaises(worker.Refused):
                self.start(name)

    def test_good_names_pass_validation(self):
        self.stub_result(0.1)
        for name in ("a", "A1", "fix-login_2.v3"):
            with self.subTest(name=name):
                self.assertEqual(self.start(name), 0)

    def test_reused_name_is_refused_and_not_charged(self):
        self.stub_result(0.5)
        self.start()
        with self.assertRaises(worker.Refused):
            self.start()
        self.assertEqual(len(self.ledger()), 1)
        self.assertEqual(self.remaining(), 49.5)


class RefusalTest(WorkerCase):
    def test_missing_worktree(self):
        self.tree.rmdir()
        with self.assertRaises(worker.Refused):
            self.start()

    def test_missing_agent(self):
        with self.assertRaises(worker.Refused):
            self.start(agent="nope")

    def test_empty_key(self):
        worker.KEY_FILE.write_text("\n")
        with self.assertRaises(worker.Refused):
            self.start()

    def test_cap_above_the_balance(self):
        with (
            mock.patch.object(worker, "START_BALANCE", 1.0),
            self.assertRaises(worker.Refused),
        ):
            self.start()

    def test_second_run_over_the_daily_cap(self):
        self.stub_result(9)
        self.start("first", cap="9")
        with self.assertRaises(worker.Refused):
            self.start("second", cap="2")

    def test_refusal_leaves_no_ledger_row(self):
        with self.assertRaises(worker.Refused):
            self.start(agent="nope")
        self.assertEqual(self.ledger(), [])


class AccountingTest(WorkerCase):
    def test_a_finished_run_settles_to_its_real_cost(self):
        self.stub_result(0.5)
        self.start()
        row = self.ledger()[0]
        self.assertEqual(
            (row["cost_usd"], row["estimate"], row["exit"], row["tokens"]),
            (0.5, False, 0, 15),
        )

    def test_balance_is_start_minus_real_cost(self):
        self.stub_result(0.5)
        self.start()
        self.assertEqual(self.remaining(), 49.5)

    def test_two_runs_add_up(self):
        self.stub_result(0.5)
        self.start("a")
        self.start("b")
        self.assertEqual((self.remaining(), worker.todays_spend()), (49.0, 1.0))

    def test_a_cost_above_the_cap_is_charged_in_full(self):
        self.stub_result(3)
        self.start()
        self.assertEqual(self.remaining(), 47.0)

    def test_a_crashed_run_stays_charged_at_its_cap(self):
        self.stub("echo boom >&2\nexit 3")
        code = self.start()
        row = self.ledger()[0]
        self.assertEqual(
            (code, row["cost_usd"], row["estimate"], self.remaining()),
            (3, 2.0, True, 48.0),
        )

    def test_a_worker_killed_mid_run_stays_charged_at_its_cap(self):
        with (
            mock.patch.object(worker, "run_claude", side_effect=KeyboardInterrupt),
            self.assertRaises(KeyboardInterrupt),
        ):
            self.start()
        row = self.ledger()[0]
        self.assertEqual(
            (row["cost_usd"], row["estimate"], self.remaining()), (2.0, True, 48.0)
        )

    def test_output_without_a_cost_stays_an_estimate(self):
        self.stub('echo \'{"result": "x"}\'')
        self.start()
        self.assertEqual((self.ledger()[0]["estimate"], self.remaining()), (True, 48.0))

    def test_a_reservation_blocks_a_parallel_run(self):
        row = {"ts": worker.now(), "name": "other", "cost_usd": 9.0}
        worker.WORKERS.mkdir()
        worker.append_row(row)
        with self.assertRaises(worker.Refused):
            self.start(cap="2")


class OutputTest(WorkerCase):
    def test_result_files_never_hold_the_key(self):
        self.stub_result(0.5, extra=f"echo {KEY} >&2")
        self.start()
        files = ("result.txt", "result.json", "stderr.txt")
        texts = [(self.workers / "run1" / f).read_text() for f in files]
        self.assertEqual([KEY in t or "sk-ant-" in t for t in texts], [False] * 3)

    def test_the_key_reaches_the_child_environment(self):
        self.stub_result(0.5, extra='echo "$ANTHROPIC_API_KEY" >&2')
        self.start()
        stderr = (self.workers / "run1" / "stderr.txt").read_text()
        self.assertEqual(stderr, "[redacted]\n")

    def test_the_subscription_token_is_dropped(self):
        self.stub_result(0.5, extra='echo "[$CLAUDE_CODE_OAUTH_TOKEN]" >&2')
        with mock.patch.dict("os.environ", {"CLAUDE_CODE_OAUTH_TOKEN": "tok"}):
            self.start()
        stderr = (self.workers / "run1" / "stderr.txt").read_text()
        self.assertEqual(stderr, "[]\n")

    def test_events_line_is_one_json_line(self):
        worker.EVENTS.write_text("")
        self.stub_result(0.5)
        self.start()
        (line,) = worker.EVENTS.read_text().splitlines()
        self.assertEqual(json.loads(line)["alarm"], "worker")

    def test_quiet_run_posts_no_alarm(self):
        worker.EVENTS.write_text("")
        self.stub_result(0.5)
        self.start(quiet=True)
        self.assertEqual(worker.EVENTS.read_text(), "")
        self.assertEqual(self.ledger()[0]["exit"], 0)

    def test_no_events_file_is_not_created(self):
        self.stub_result(0.5)
        self.start()
        self.assertFalse(worker.EVENTS.exists())

    @unittest.skipUnless(shutil.which("git"), "needs git")
    def test_a_key_written_into_the_worktree_is_flagged(self):
        subprocess.run(["git", "init", "-q", str(self.tree)], check=True)
        self.stub_result(0.5, extra=f"echo {PREFIX}api03-leak > leak.txt")
        self.start()
        self.assertTrue(self.ledger()[0].get("leak_suspected"))

    @unittest.skipUnless(shutil.which("git"), "needs git")
    def test_a_clean_worktree_is_not_flagged(self):
        subprocess.run(["git", "init", "-q", str(self.tree)], check=True)
        self.stub_result(0.5, extra="echo fine > ok.txt")
        self.start()
        self.assertNotIn("leak_suspected", self.ledger()[0])


class MainTest(WorkerCase):
    def run_main(self, *argv):
        err = io.StringIO()
        with (
            mock.patch("sys.argv", ["claude-worker", *argv]),
            contextlib.redirect_stderr(err),
        ):
            return worker.main(), err.getvalue()

    def test_refusal_exits_2_with_a_message(self):
        code, err = self.run_main(
            "run", "bad name", "dev", str(self.tree), str(self.prompt)
        )
        self.assertEqual((code, "refused: bad run name" in err), (2, True))

    def test_balance_prints_remaining(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.run_main("balance")
        self.assertIn("remaining $50.00", out.getvalue())


if __name__ == "__main__":
    unittest.main()
