"""The Emacs MCP server: JSON arguments travel as JSON text, the caller is the server's."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(
    HERE, "..", "..", "container", "channels", "homun", "servers", "emacs.py"
)


def load():
    spec = importlib.util.spec_from_file_location("emacs_server", SERVER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ToolWords(unittest.TestCase):
    def setUp(self):
        self.server = load()
        args = [{"key": "id", "type": "string"}, {"key": "ops", "type": "json"}]
        self.tool = self.server.Tool(
            {"name": "stage patch", "doc": "", "args": args, "caller": True}
        )

    def test_json_and_caller(self):
        words = self.tool.words(
            {"id": "roll", "ops": [{"path": "/s/current", "set": 1}]}
        )
        self.assertEqual(words[:4], ["stage", "patch", "id", "roll"])
        self.assertEqual(words[5], '[{"path": "/s/current", "set": 1}]')
        self.assertEqual(words[-2:], ["caller", self.server.ROLE])

    def test_caller_not_given(self):
        with self.assertRaises(ValueError):
            self.tool.words({"id": "roll", "caller": "cal"})

    def test_json_schema_untyped(self):
        self.assertNotIn(
            "type", self.tool.described()["inputSchema"]["properties"]["ops"]
        )


if __name__ == "__main__":
    unittest.main()
