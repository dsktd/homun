"""Shadow test of `homund approve` against container/permission-hook-legacy.sh: the same request
file and the same decision for each kind of answer, and the shim's fallback to the legacy hook."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LEGACY = ["sh", str(ROOT / "container/permission-hook-legacy.sh")]
HOMUND = os.environ.get("HOMUND") or str(ROOT / "core/homund/target/debug/homund")
NEW = [HOMUND, "approve"]
HOOK = json.dumps(
    {"tool_name": "Bash", "tool_input": {"command": "ls /"}, "agent_id": "a1", "agent_type": "X"}
)


@unittest.skipUnless(Path(HOMUND).exists() and shutil.which("jq"), "homund or jq missing")
class ApproveShadowTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name) / "approve"
        role = Path(tmp.name) / "is-role.sh"
        role.write_text("exit 0\n")
        self.env = {
            **os.environ,
            "APPROVE_DIR": str(self.dir),
            "APPROVE_TIMEOUT": "5",
            "HOMUN_IS_ROLE": str(role),
        }
        self.env.pop("HOMUN_HEADLESS", None)
        # the legacy hook calls /opt/homun/is-role.sh: run it through a patched copy
        patched = Path(tmp.name) / "legacy.sh"
        patched.write_text(
            (ROOT / "container/permission-hook-legacy.sh")
            .read_text()
            .replace("/opt/homun/is-role.sh", str(role))
        )
        self.legacy = ["sh", str(patched)]

    def hook(self, tool, answer):
        """Run the hook, answering its request with ANSWER; return (stdout, request)."""
        proc = subprocess.Popen(
            tool, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=self.env
        )
        seen = {}

        def answerer():
            for _ in range(100):
                files = list((self.dir / "requests").glob("*.json"))
                if files:
                    seen.update(json.loads(files[0].read_text()))
                    (self.dir / "answers" / seen["id"]).write_text(answer)
                    return
                time.sleep(0.05)

        t = threading.Thread(target=answerer)
        t.start()
        out, _ = proc.communicate(HOOK, timeout=20)
        t.join()
        self.assertEqual([], list((self.dir / "requests").glob("*")))
        return out, seen

    def test_answers_match_legacy(self):
        for answer in ["allow", "deny", '{"behavior":"deny","message":"too risky"}']:
            old, old_req = self.hook(self.legacy, answer)
            new, new_req = self.hook(NEW, answer)
            self.assertEqual(json.loads(old), json.loads(new), answer)
            for key in ("tool", "summary", "input", "agent", "timeout"):
                self.assertEqual(old_req[key], new_req[key])

    def test_shim_falls_back_when_homund_lacks_approve(self):
        fake = Path(self.dir.parent) / "homund"
        fake.write_text("#!/bin/sh\nexit 2\n")
        fake.chmod(0o755)
        self.env["HOMUND"] = str(fake)
        out, req = self.hook(["sh", str(ROOT / "container/permission-hook.sh")], "allow")
        self.assertEqual("allow", json.loads(out)["hookSpecificOutput"]["decision"]["behavior"])

    def test_headless_steps_aside(self):
        self.env["HOMUN_HEADLESS"] = "1"
        r = subprocess.run(NEW, input=HOOK, capture_output=True, text=True, env=self.env)
        self.assertEqual((0, ""), (r.returncode, r.stdout))


if __name__ == "__main__":
    unittest.main()
