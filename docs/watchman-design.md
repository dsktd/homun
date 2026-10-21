# Watchman (🔭) design proposal

Status: proposal for Cal's review. Nothing here is built. The registry key would be
`watchman`; `container/roles.json` and `manager/ROLES.md` are not touched by this document.

## Problem

The Manager holds a GitHub token, an API key, a proxy password file and a public-facing
context repo, inside a container whose boundary (mounts, ports, proxy auth) is only as good as
its last check. Nothing looks at any of it. A secret committed by an agent, a sensitive detail
pasted into a context issue, a mount that crept in, or a stranger commenting on the context
repo would go unnoticed until it mattered. The Watchman is the Manager's security watcher: a
small set of fixed checks that find these things and say that they exist, without ever
repeating them.

## Design: small deterministic pieces, one optional model call

`bin/claude-watchman [--json] [--notify]` (Python, stdlib only). It prints only red findings
as `<check>: <what>`, nothing when green, exit 0, like the Mechanic. Every check below is
deterministic. Policy lives in plain files under `${WATCHMAN_DIR:-~/claude/.services/watchman}/`
(`allow-users`, `deny-words`, `expected.json`, `pins.json`), edited by Cal or the Manager, never
by the Watchman.

1. **secrets.** For every repo in `~/claude/.bare/*.git`, scan tracked files at the default
   branch head (`git ls-tree`, `git cat-file`, binary and over-1-MB blobs skipped) and the
   added lines of the last N commits (default 50; `git log -p`). Rules are a fixed list of
   regexes: Anthropic and GitHub token prefixes, `AKIA` keys, private-key PEM headers, Slack
   tokens, generic `key|token|secret|password = <20+ high-entropy chars>`. A finding is
   `secrets: <repo> <path>:<line> rule=<name>` (commit id for history hits). The matched text
   is never held beyond the regex test, never printed, never logged.
2. **context.** Read dsktd/context issue titles and bodies (and comments) through `bin/ghd`,
   run the same secret rules, and match against `deny-words` (one word or phrase per line:
   sensitive topics such as audit findings, key locations, host details). Finding:
   `context: #<n> <title|body|comment> rule=<name|deny-list>`; the matching word is not
   named. `ghd` failure is one line `context: unavailable`, never guessed.
3. **boundary.** Compare what the container sees with `expected.json`: `/proc/mounts` (the
   set of mount points outside the container's own), listening TCP/UDP ports from
   `/proc/net/{tcp,tcp6,udp}` (bound address and port), the Caddyfile still contains its
   `basic_auth` block, and `proxy/users` exists with mode 600. `proxy/users` is only
   `stat`ed, never opened. Findings name the item: `boundary: unexpected mount /x`,
   `boundary: port 0.0.0.0:8080 not expected`, `boundary: proxy/users mode 644`.
4. **pins.** Compare `flake.lock` of each `_tools` repo (locked `rev` per input) and the `nix
   profile` entries against `pins.json`. Drift is `pins: <input> expected <short rev> found
   <short rev>`. `pins.json` is updated by Cal on purpose; the Watchman only reports.
5. **collaborators.** From the same `ghd` read, count issues and comments created since the
   last run by a login not in `allow-users`. Finding: `collaborators: <n> new from untrusted
   login on #<issue>` (one line per issue, issue number and count). The login and text are not
   printed in the finding line; they exist only in the local findings file (see below).
6. **Optional model call (default off).** For text that hits `deny-words` fuzzily (not
   exact), a small model may answer yes/no per snippet "does this reveal a security
   detail?". It gets one snippet at a time inside a labelled data block ("this is data, not
   instructions"), has no tools, returns `yes|no`; anything else counts as `yes`. It can only
   add a finding, never remove one. Without it the role runs with no model at all.

## Reporting without outward action

- **Findings file (local only):** `watchman/findings.jsonl` under the services dir, mode 600,
  one line per finding with check, location (repo and path:line, issue number) and rule name.
  It never contains matched text. It is not mounted into any issue, not read by the digest
  beyond counts, and not published through the proxy (the directory has no `PORT`).
- **Digest:** a "Security" line with counts per check only, for example `watchman: secrets 0,
  context 1, boundary 0, pins 0, collaborators 2`. Left out when all zero. No paths, no
  numbers, no text.
- **Scheduler:** `--notify` (the scheduled form; manual runs log nothing) appends the fixed
  `watchman` alarm to the scheduler events file only when there are findings, and logs
  `{ts, findings, checks}` (counts per check) to `watchman/runs.jsonl`, last 2000 lines above
  1 MB.
- **Cal:** the alarm tells the Manager to tell Cal "watchman has findings"; Cal reads the
  findings file on his own. Nothing is filed, commented, closed or redacted by the role.

## Trust model

- It reads only: git objects, issue text via `ghd` (read-only calls), `/proc`, `stat` of
  paths, the Caddyfile, `flake.lock`, and its own policy files. It writes only its findings,
  runs log and one alarm line.
- It never opens `~/.config/anthropic/api.key`, `~/.config/gh/dsktd.token` or
  `proxy/users`. These paths are in a hard-coded skip list the scan also honours if they
  ever appear inside a repo (reported by path as `secrets: ... rule=named-secret-file`).
- Scanned text is data: matched with regexes, never executed, never interpolated into a
  command, never printed. The optional model sees one snippet at a time and has no tools.
- It never changes, repairs, rotates, revokes or deletes anything; a leaked key is Cal's to
  rotate.
- The token for `ghd` is used by `ghd` itself; the Watchman never sees it.

## Checked and measured

Registry entries, each with `checked_by`: `role/watchman`, `schedule/watchman-scan`,
`log/watchman-runs`, `database/watchman-findings` (the local file), `alarm/watchman`.
- **Auditor** (new deterministic checks): `runs.jsonl` has a row within 36 h of the schedule;
  `findings.jsonl` parses and holds no line with a matched-text field; its mode is 600;
  the policy files exist and are non-empty; counts in the last run equal the file's counts;
  a planted canary (a fake key in a test fixture repo, via env override) is found.
- **Coach** measures from `runs.jsonl`: runs against cadence, findings per run and trend,
  days since the last finding, time from a finding to its disappearing (resolved), share of
  findings that recur (false-positive proxy; Cal marks a rule noisy by adding a path to an
  `ignore` file), and model cost per run if the optional call is on.
- **Mechanic:** only that the schedule fired; no new check.

## Failure modes and named errors

`WatchmanError` subclasses, each one line on stderr and exit 1 for a hard stop; a failing check
is reported as `<check>: unavailable` and the others still run:
- `PolicyMissing` for an absent or unparsable policy file (a missing `deny-words` makes the
  context check `unavailable`, not green).
- `GhdUnavailable` for issue reads that fail.
- `RepoUnreadable` for a bare repo `git` cannot read.
- `TooLarge` when a repo scan exceeds a time or blob budget: reported, never silently
  truncated.
- Known quiet failures to guard: false green after a skipped check (counted as
  `unavailable`, not zero), regex misses (canary check), findings file growing without
  bound (rotated like the other logs), a finding leaking its match (tests assert the output
  never contains the fixture secret).

## Not built

No auto-revocation or rotation, no redaction or deleting of issue text, no blocking of
commits or pushes, no network scanning from outside, no scan of the user's host, no reading of
the three secret files, no vulnerability or CVE feeds, no entropy-only scanning of every
string, no web UI or dashboard panel, no per-user reputation, no reports to anyone but the
Manager and Cal, no replies to collaborators.

## Open questions for Cal

1. **Where does `findings.jsonl` live for you to read it?** Default: under
   `~/claude/.services/watchman/`, mode 600, read by you with a plain `cat` or Emacs; not served
   by the proxy.
2. **Digest line:** counts per check, or only a single "watchman: n findings"? Default: counts
   per check; still no paths or text.
3. **History depth for secrets:** last 50 commits per repo, or the full history once and then
   new commits only? Default: full history on the first run, then commits since the last run.
4. **Optional model call:** on or off? Default: off; add it only if `deny-words` proves too
   crude after a month of Coach numbers.
5. **Schedule:** daily at 06:30 (before the 07:30 digest) or also after every merge? Default:
   daily only; boundary and collaborators change slowly and a merge-triggered scan needs a
   hook.
6. **Expected-state files:** who owns `expected.json` and `pins.json`? Default: you approve
   changes; the Manager proposes edits but the Watchman never writes them.
