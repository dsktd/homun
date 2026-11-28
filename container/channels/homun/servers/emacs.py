#!/usr/bin/env python3
"""Emacs MCP server (stdio): each entry of the cockpit's Emacs API as a typed tool.

Nothing is defined here: the tools are generated from the registry of
container/emacs/homun-api.el (`api schema`), and a call is forwarded as the constant form
(homun-rpc) with the entry and its `key value` words as arguments, so no text a caller
passes is evaluated as Lisp. Calls go through the eval wrapper (homun-eval), which logs
each one to eval-log.jsonl with kind `rpc`. Raw eval is not a tool.

COCKPIT_OBJECTS (space separated) narrows the tools to those objects; default all.
"""

import json
import os
import re
import subprocess
import sys

SERVICE = os.path.expanduser("~/claude/.services/emacs")
SOCKET = os.path.join(SERVICE, "socket")
CACHE = os.path.join(SERVICE, "api-schema.json")
WRAPPER = os.environ.get("HOMUN_EVAL_WRAPPER", "/opt/homun/homun-eval")
FORM = "(homun-rpc)"
TIMEOUT = 20
HIDDEN = ("api list", "api schema")
ESCAPE = re.compile(r"\\(.)", re.DOTALL)
ESCAPED = {"n": "\n", "t": "\t", "f": "\f", "e": "\x1b"}
JSON_TYPES = {"int": "integer", "bool": "boolean"}
SYMBOL = "^[a-z][a-z0-9-]*$"
ROLE = os.environ.get("HOMUN_ROLE") or os.environ.get("CLAUDE_ROLE") or "manager"
INSTRUCTIONS = (
    "Typed calls into the cockpit's Emacs daemon, one tool per entry of its API registry "
    "(the same entries as the homun-emacs command). Prefer these over emacsclient --eval."
)


class Daemon:
    """The cockpit's Emacs, reached through the logged eval wrapper."""

    def command(self, words):
        head = (
            [sys.executable, "-I", WRAPPER]
            if os.path.exists(WRAPPER)
            else ["emacsclient"]
        )
        guard = ["--"] if any(w.startswith("-") for w in words) else []
        return head + ["-s", SOCKET, "--eval", FORM] + guard + words

    def call(self, words):
        """(ok, body) of one registry call."""
        if not os.path.exists(SOCKET):
            return False, f"no server at {SOCKET}"
        env = dict(os.environ, HOMUN_EVAL_KIND="rpc")
        try:
            p = subprocess.run(
                self.command(words),
                capture_output=True,
                timeout=TIMEOUT,
                env=env,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as e:
            return False, f"emacsclient failed: {e}"
        out = p.stdout.decode(errors="replace").strip()
        if p.returncode != 0 or not (out.startswith('"') and out.endswith('"')):
            return (
                False,
                f"emacsclient failed: {p.stderr.decode(errors='replace').strip() or out}",
            )
        text = ESCAPE.sub(lambda m: ESCAPED.get(m.group(1), m.group(1)), out[1:-1])
        head, _, body = text.partition("\n")
        return head == "ok", body if head == "ok" else f"{head[4:]}: {body}"


class Tool:
    """One registry entry as an MCP tool."""

    def __init__(self, entry):
        self.entry = entry["name"]
        self.name = re.sub(r"[^a-z0-9]+", "_", self.entry)
        self.doc = entry["doc"]
        self.args = entry.get("args", [])
        self.caller = entry.get("caller", False)

    def described(self):
        required = [a["key"] for a in self.args if a.get("required")]
        schema = {
            "type": "object",
            "properties": {a["key"]: self.property(a) for a in self.args},
            "additionalProperties": False,
        }
        if required:
            schema["required"] = required
        return {"name": self.name, "description": self.doc, "inputSchema": schema}

    @staticmethod
    def property(arg):
        kind = arg["type"]
        if kind == "json":
            return {"description": "a JSON value (object or array)"}
        out = {"type": JSON_TYPES.get(kind, "string")}
        if kind == "enum":
            out["enum"] = arg["choices"]
        if kind == "symbol":
            out["pattern"] = SYMBOL
        if kind == "data":
            out["description"] = "Lisp data as text, e.g. (:value 1.0) or t"
        if "max" in arg:
            out["maximum"] = arg["max"]
        if "default" in arg:
            out["default"] = arg["default"]
        return out

    def words(self, given):
        """The call as words; raises ValueError on a value the wire cannot carry."""
        words = self.entry.split(" ")
        if "caller" in given:
            raise ValueError("caller: filled in by the server")
        for key, value in given.items():
            if value is None:
                continue
            if isinstance(value, (dict, list)):
                value = json.dumps(value)
            elif isinstance(value, bool):
                value = "yes" if value else "no"
            elif isinstance(value, float) and value.is_integer():
                value = int(value)
            if str(value) == "":
                raise ValueError(f"{key}: empty value")
            words += [key, str(value)]
        if self.caller:
            words += ["caller", ROLE]
        return words


class Registry:
    """The daemon's entries as tools; the last good list is kept for when it is down."""

    def __init__(self, daemon, objects):
        self.daemon = daemon
        self.objects = objects
        self.tools = {}

    def load(self):
        ok, body = self.daemon.call(["api", "schema"])
        try:
            if ok:
                entries = json.loads(body)
                self.keep(body)
            else:
                with open(CACHE) as f:
                    entries = json.load(f)
        except (OSError, ValueError):
            entries = []
        tools = [Tool(e) for e in entries if e["name"] not in HIDDEN]
        if self.objects:
            tools = [t for t in tools if t.entry.split(" ")[0] in self.objects]
        self.tools = {t.name: t for t in tools}
        return tools

    @staticmethod
    def keep(body):
        try:
            with open(CACHE + ".tmp", "w") as f:
                f.write(body)
            os.replace(CACHE + ".tmp", CACHE)
        except OSError:
            pass

    def call(self, name, given):
        """(ok, text) of the tool NAME called with the arguments GIVEN."""
        tool = self.tools.get(name) or {t.name: t for t in self.load()}.get(name)
        if tool is None:
            return False, f"no tool {name}"
        try:
            return self.daemon.call(tool.words(given))
        except ValueError as e:
            return False, f"invalid: {e}"


class Server:
    """JSON-RPC over stdio, one message per line: initialize, ping, tools/list, tools/call."""

    def __init__(self, registry):
        self.registry = registry

    def result(self, method, params):
        if method == "initialize":
            return {
                "protocolVersion": params.get("protocolVersion", "2024-11-05"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "emacs", "version": "1"},
                "instructions": INSTRUCTIONS,
            }
        if method == "ping":
            return {}
        if method == "tools/list":
            return {"tools": [t.described() for t in self.registry.load()]}
        if method == "tools/call":
            ok, text = self.registry.call(
                params.get("name"), params.get("arguments") or {}
            )
            return {"content": [{"type": "text", "text": text}], "isError": not ok}
        return None

    def reply(self, message):
        """The answer to one message, or None for a notification."""
        if "id" not in message:
            return None
        answer = {"jsonrpc": "2.0", "id": message["id"]}
        result = self.result(message.get("method"), message.get("params") or {})
        if result is None:
            answer["error"] = {
                "code": -32601,
                "message": f"no method {message.get('method')}",
            }
        else:
            answer["result"] = result
        return answer

    def serve(self, lines, out):
        for line in lines:
            try:
                message = json.loads(line)
            except ValueError:
                continue
            answer = self.reply(message) if isinstance(message, dict) else None
            if answer is not None:
                out.write(json.dumps(answer) + "\n")
                out.flush()


if __name__ == "__main__":
    Server(Registry(Daemon(), os.environ.get("COCKPIT_OBJECTS", "").split())).serve(
        sys.stdin, sys.stdout
    )
