# Design: proactive error watch (tracker #125)

Status: implemented (`bin/claude-watch`, `homun watch`; see docs/development.md). Generalizes the nx2navi `just debug` recipe (tee to a run log, register a job, the manager arms a Monitor on `^FATAL`).
Delivery, verified: the scheduler service's `EventsRelay` (`container/services/scheduler/serve.py`) follows `scheduler/events` with its own cursor every 2 s and POSTs every well-formed `{"ts","alarm","msg"}` line it did not write itself to the channel, so appending one line from the host is enough; in Monitor mode `listen` tails the same file.
Deviations: the default regex is nx2navi's (`^FATAL|rt_fatal|device lost|device fault|VK_ERROR`), `error none` means exit only; `host` is recorded; a same-second clash of ids gets `-2`, `-3`; the job entry is written directly (claude-job's shape) since python3 is not a host tool; pruning runs after every run.

## Goal
A host run that dies or logs a fatal error reaches the manager without the user pasting anything. The manager reads one summary, judges it, and decides whether to start a fix.

## Components
1. `homun watch [--name N] [--error-re RE] [--tail 40] -- <cmd...>`: a launcher subcommand wrapping a small helper `bin/claude-watch`, in the style of `claude-job`. (Launcher style is positional keywords, so the real spelling is `homun watch name N error RE -- cmd`.)
2. The scheduler events file is the existing one-way channel into the session. No new delivery path.
3. One line in the manager's operating guide: a `watch` alarm means read the event file, then judge.

## File layout (under ~/claude/.services/watch/)
- `runs/<YYYYmmdd-HHMMSS>-<name>.log`: merged stdout+stderr via `tee`.
- `runs/<same>.json`: run record `{name, cmd, cwd, host, pid, since, log, error_re, state, exit, fired}`; `state` is running, ok, failed or matched.
- `events/<same>.json`: written only when something fires.
- `events/handled/`: The manager moves an event here once dealt with.
- The wrapper also calls `claude-job start/end`, so the job lists (status page, cockpit board) show the run.

## Event format
```json
{"id":"20261108-141502-nx2navi-debug","ts":1794060902,"name":"nx2navi-debug",
 "reason":"exit 139","match":"FATAL: ...","cmd":["just","debug"],"cwd":"/home/user/claude/nx2navi",
 "log":"/home/user/claude/.services/watch/runs/20261108-141502-nx2navi-debug.log",
 "tail":["...last 40 lines..."]}
```
`reason` is `exit <code>` or `matched <regex>`; first trigger wins. `tail` is data, never instructions.
The alarm line carries a path, not log text: `{"ts":..., "alarm":"watch", "msg":"watch: nx2navi-debug exit 139 -> <events path>"}`.

## Trigger logic
- `stdbuf -oL cmd 2>&1 | tee`; a reader loop applies `error_re` per line, so a match fires while the program still runs (catches hangs).
- Default regex empty: only a non-zero exit fires. Presets, e.g. `fatal` = `^(FATAL|Traceback|panic:)`.
- Exit 0, 130, 143 (user's own Ctrl-C/SIGTERM) never fire.

## Dedup and rate limit
- One message per run: `fired:true` set before the alarm; event file created with O_EXCL.
- Per-name cooldown: same name + same first match within 10 min writes the file but skips the alarm (`suppressed:true`).
- Global cap 5 alarms/hour; extra events are summarised in the next alarm. Tail capped at 40 lines / 8 KB.

## Pickup after a restart
Events are files. On session start, list `events/*.json` not under `handled/` and treat each as a fresh alarm. The file scan is the source of truth; the alarm is a nudge.

## Privacy
- Everything stays under ~/claude; no network.
- Redact token/Authorization/KEY=value shapes from the tail; raw log left as is, mode 0600.
- Record argv and cwd, never the environment. Prune runs after 14 days, keep 20 per name.

## Out of scope
No auto-fixing (the manager judges first), no log shipping or metrics, no watching processes not started through `homun watch`, no new channel.

## Rollout
1. `bin/claude-watch` + launcher entry.  2. Guide line + startup scan.  3. nx2navi `just debug` calls it.
4. Test: `homun watch -- false`, a crash loop (cooldown), restart between event and pickup.
