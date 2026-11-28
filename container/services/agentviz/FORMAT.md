# agentviz event stream

`~/claude/.services/agentviz/events.jsonl`: one JSON object per line, appended; rotated at 5 MB to
`events.jsonl.1`. Consumers follow it (`tail -F`) and must survive the rotation.

```json
{"t": 1795806726.9, "agent": "a62572f7", "label": "Transcript reading/focus mode", "model": "claude-opus-5-5", "kind": "edit", "path": "/home/user/claude/_tools/homun/container/emacs/claude-transcript.el", "repo": "/home/user/claude/_tools/homun", "ok": true}
```

- `t`: epoch seconds (float), the time of the tool call.
- `agent`: first 8 characters of the transcript's agent id (the session uuid for a main session).
- `label`: the task description from the agent's `.meta.json`; `main` for a main session.
- `model`: model of the latest assistant message seen, or null before the first one.
- `kind`: `read`, `edit` (Edit, MultiEdit, NotebookEdit), `write`, `search` (Grep, Glob), `bash`,
  `build` (cargo build/check/clippy/run/install, homun-compile, nix build), `test` (cargo test,
  nix flake check/test, `nu tests/run.nu`), `start`, `finish`.
- `path`: absolute file path; for `bash`, `build`, `test` and searches without a path, the cwd; null
  for start/finish before any call.
- `repo`: `<ws>/<repo>` root under `~/claude` that holds `path`, else null.
- `ok`: true/false from the tool result; null for start/finish and calls that never got a result.

A tool call is written when its result arrives. Only agents active in the last 2 minutes are
followed; `finish` is written when `.meta.json` says finished or the transcript goes idle.

## Gource

`bin/agentviz-gource` (runs beside the service) writes `gource.log` in gource's custom format
(`time|user|A/M/D|path`; user is the label, path relative to `~/claude`). On the host (Nushell):

    tail -f ~/claude/.services/agentviz/gource.log | SDL_VIDEODRIVER=wayland nix run nixpkgs#gource -- --realtime --log-format custom --hide filenames --auto-skip-seconds 1 -

nixpkgs gource (0.56) uses SDL2; `SDL_VIDEODRIVER=wayland` makes it native Wayland.
