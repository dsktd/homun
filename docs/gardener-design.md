# Gardener (🧹) design proposal

Status: proposal for Cal's review. Nothing here is built. The registry key would be
`gardener`; `container/roles.json` and `manager/ROLES.md` are not touched by this document.

## Problem

Work leaves debris. Merged worktrees stay in workspaces, merged local branches pile up,
scratch directories under `~/claude` and `/tmp/claude-0` outlive their tasks, test helpers
(the open issue: `socat` processes outliving test scripts) linger in the container, and
sockets point at nobody. The maint service already scans the clones daily and writes
`hygiene.jsonl`, report only; nothing turns that into a decision. The Gardener reads that
file and the filesystem, and writes a daily "safe to remove" list. It never removes anything.

## Design: small deterministic pieces, one optional model call

`bin/claude-gardener [--json] [--notify]` (Python, stdlib only). It prints one proposal per
line, nothing when there is nothing to propose, exit 0. Inputs: `hygiene.jsonl` (from
`container/services/maint`, `HYGIENE_FILE` overrides), `git` read calls, `stat`, `/proc`.
Thresholds live in `${GARDENER_DIR:-~/claude/.services/gardener}/thresholds.json`.

1. **worktrees.** From `hygiene.jsonl`: a worktree that is `merged-by-cherry` (or whose
   branch subject/`(#N)` appears in the default branch log, since cherry misses squashes),
   not `dirty`, not `missing`, `ahead` 0 of its upstream (no unpushed commit), and passing
   the safety rules below. Proposal: `remove worktree <path> (merged, clean)`, with the
   command it would take (`git -C <bare> worktree remove <path>`), printed, not run.
2. **branches.** `branches_without_worktree` that are merged (same rule as above) and not the
   default: `delete branch <repo>:<name> (merged)`. A branch in `branches_without_upstream`
   that is not merged is never proposed; it is listed once as `keep: <repo>:<name> local
   only, <n> commits`, so Cal knows it exists.
3. **scratch.** Directories directly under `~/claude` and `/tmp/claude-0`, and not owned:
   not a worktree path in any `git worktree list`, not under a protected name, not a
   scratchpad of a live session (`/tmp/claude-0/<project>/<session>` where the session
   transcript was touched in the last N days), with newest mtime of any file inside older
   than N days (default 7). Proposal: `remove dir <path> (<size>, idle <d> days)`. Empty
   workspace directories (`~/claude/<ws>` with no children) are `rmdir <path>`.
4. **processes.** Read `/proc/<pid>/{cmdline,stat,status}`: a process named in a fixed list
   (`socat`, plus any pattern in `thresholds.json`) whose parent is PID 1 or a dead shell,
   started more than N minutes ago (default 60) and whose working directory or open files
   are not a running service's directory (`claude-services list`). Proposal: `kill <pid>
   <name> (orphan, up <d>)`. The Gardener never signals; the Manager or Cal does.
5. **sockets.** Unix sockets (stale `*.sock` files under `/tmp/claude-0` and `~/claude` outside
   protected paths) that no process listens on (`/proc/net/unix` has no entry) and that are
   older than N hours (default 24): `remove socket <path> (nobody listening)`.
6. **Optional model call (default off).** For scratch directories only: given the file names
   and sizes (not contents) inside a candidate, a small model may answer one line, "scratch
   of what?" to help Cal decide. It has no tools, gets names inside a labelled data block,
   and cannot add or remove a proposal; it annotates. Without it the role runs with no model.

## Safe-deletion rules

Applied to every candidate before it is listed; a candidate failing any rule is dropped, and
counted per rule in the run record (`skipped`), never silently:
- Never touch `~/claude/_tools`, `~/claude/.services`, `~/claude/.bare`, or anything beneath
  them, and never `~/claude` itself, `~/.claude`, `~/.config`, `/nix`, or a mount from
  `c mounts` (checked against `/proc/mounts`). The list is hard-coded; `thresholds.json` can
  add paths but never remove one.
- Never a dirty worktree (`git status --porcelain` non-empty, untracked files included), or
  one whose `dirty` is unknown.
- Never anything with a modification time inside the last hour (any file inside, not just the
  directory), nor a path a running process has as cwd or open file.
- Never a path or branch with unpushed commits: ahead of its upstream, or with no upstream
  and any commit not reachable from the default branch (this includes merged-looking
  branches whose merge check is only a hint).
- Never resolve through a symlink: a candidate that is a symlink, or whose realpath leaves
  its listed parent, is dropped.
- Never a worktree on a default branch, a detached HEAD with commits not on any branch, or a
  workspace of an in-progress issue the Scribe or the Manager lists as open (optional, when
  `scribe/proposals` or the board is available; absent data does not relax any other rule).
- Names are matched strictly (`^[A-Za-z0-9._/-]+$`); a path with anything else is reported as
  `odd name` and not proposed.

## Reporting without outward action

- **Proposals file (local):** `gardener/proposals.md` under the services dir, rewritten on
  each run (previous kept as `proposals.prev.md`): a list `- [ ] remove worktree
  ~/claude/old-ws/foo  merged, clean  git -C ... worktree remove ...`, plus a total of
  reclaimable size. Not served by the proxy (no `PORT`).
- **Applying:** the Manager or Cal runs the printed command; the next run no longer lists
  it. A rejected line goes into `gardener/keep` (path or branch per line) and is skipped.
- **Digest:** a "Housekeeping" line with counts: `gardener: worktrees 2, branches 5, dirs 1,
  procs 0, sockets 0 (1.2 GB)`. Left out when all zero.
- **Scheduler:** `--notify` (the scheduled form; manual runs log nothing) logs `{ts,
  findings, checks}` (counts per check, plus `skipped` per rule) to `gardener/runs.jsonl`
  (last 2000 lines above 1 MB) and appends the fixed `gardener: <n> proposals` alarm only
  when there are any.

## Trust model

- It reads `hygiene.jsonl`, git metadata through read-only `git` calls, `stat`, `/proc`, and
  its own policy files. It writes only the proposals files, the runs log and one alarm line.
  It never runs `rm`, `rmdir`, `git worktree remove|prune`, `git branch -d`, `kill`, or
  anything else that changes the filesystem or a process; a test checks the module has no
  such call.
- It does not read file contents in candidates (only names, sizes, mtimes), never opens the
  three secret files, and never follows symlinks.
- The commands printed in proposals are built from the structured fields, not from file
  names concatenated raw; every path is quoted with `shlex.quote` and passes the name rule.
- Staleness of `hygiene.jsonl` matters: if the file is older than 36 h, the Gardener lists
  nothing from checks 1 and 2 and reports `worktrees: hygiene.jsonl stale`.

## Checked and measured

Registry entries, each with `checked_by`: `role/gardener`, `schedule/gardener-scan`,
`log/gardener-runs`, `log/gardener-proposals`, `alarm/gardener`.
- **Auditor** (new deterministic checks): `runs.jsonl` has a row within 36 h of the schedule;
  counts in the last run equal the lines in `proposals.md`; no proposal lies beneath a
  protected path or is a symlink (recomputed independently); `hygiene.jsonl` is not older
  than its schedule; a fixture tree (env override) with a dirty worktree, a fresh file and
  an unpushed branch yields no proposal for them.
- **Coach** measures from `runs.jsonl`: runs against cadence, proposals per run and trend,
  proposals applied against rejected (`keep` growth: the false-positive rate per check),
  reclaimed space (sum of sizes of proposals that disappear without being in `keep`),
  clutter age (oldest merged worktree still present), and model cost per run if the
  optional call is on.
- **Mechanic:** only that the schedule fired; disk-usage red remains its check.

## Failure modes and named errors

`GardenerError` subclasses, one line on stderr and exit 1 for a hard stop; a failing check
is reported as `<check>: unavailable` and the others still run:
- `HygieneMissing` for an absent or unparsable `hygiene.jsonl`; `HygieneStale` as above.
- `RepoUnreadable` for a clone `git` cannot read (the `{"repo","error"}` rows).
- `PolicyMissing` for an absent or unparsable `thresholds.json`.
- `UnsafePath` internal: a candidate failed a rule; counted, not fatal.
- Known quiet failures to guard: a squash-merged worktree that `merged-by-cherry` calls
  unmerged (it is then simply not proposed: safe, and the Scribe's merged check covers
  it), a `missing` worktree path that is only invisible to the container (never proposed,
  never pruned), a process in a legitimate long test (age threshold and the cwd rule), a
  scratch directory a session reopens after a week (the mtime rule and `keep`), a race
  between the scan and a new commit (rules are re-checked immediately before listing and
  the Manager rechecks before running), and sizes taking long on a huge tree (a budget;
  over it, `<path> size unknown`).

## Not built

No deletion, pruning, killing or moving of anything; no `git gc` or maintenance (maint does
that); no fetching; no cleanup of the Nix store or caches; no cleanup of images or the
host; no log rotation; no policy to remove unmerged work or anything with unpushed commits
under any option; no cron that applies proposals; no web UI; no reading of file contents.

## Open questions for Cal

1. **Age thresholds:** scratch directories idle 7 days, sockets 24 hours, processes 60
   minutes? Default: those, in `thresholds.json`.
2. **Who runs the proposals?** Default: the Manager applies worktree and branch lines after
   rechecking and tells you; directory removals and `kill` lines wait for your yes.
3. **Branches with no upstream and unmerged:** list as `keep` only (default), or stay silent?
4. **Process patterns beyond `socat`:** any other helpers you have seen outlive tests?
   Default: `socat` only, extendable in `thresholds.json`.
5. **Optional model annotation of scratch directories:** on or off? Default: off.
6. **Schedule:** daily at 06:45, after maint's daily pass writes `hygiene.jsonl` and before
   the digest? Default: yes, with a staleness guard if maint has not yet run.
