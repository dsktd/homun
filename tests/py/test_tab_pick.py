"""The Zellij tab picker: C-SPC TAB TAB reaches bin/claude-tab-pick."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import os
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class TabPickTest(unittest.TestCase):
    def test_tab_key_enters_tab_mode_from_the_prefix(self):
        config = (ROOT / "zellij/config.kdl").read_text()
        self.assertRegex(config, r'bind "Tab" \{ SwitchToMode "tab"; \}')

    def test_tab_mode_runs_the_picker_in_a_floating_pane(self):
        config = (ROOT / "zellij/config.kdl").read_text()
        mode = re.search(r"\n    tab \{\n(.*?)\n    \}\n", config, re.DOTALL).group(1)
        self.assertRegex(mode, r'Run "claude-tab-pick" \{ floating true;')
        self.assertIn('SwitchToMode "locked"', mode)

    def test_picker_lists_tab_names_and_goes_by_name(self):
        script = ROOT / "bin/claude-tab-pick"
        self.assertTrue(os.access(script, os.X_OK))
        text = script.read_text()
        self.assertIn("zellij action query-tab-names", text)
        self.assertIn("zellij action go-to-tab-name $t", text)


if __name__ == "__main__":
    unittest.main()
