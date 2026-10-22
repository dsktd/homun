# Scribe (🧾) design proposal

Status: proposal for Cal's review. Nothing here is built. The registry key would be `scribe`;
`container/roles.json` and `manager/ROLES.md` are not touched by this document.

## Problem

The dsktd/context issue board is the live status and work queue, and the Manager alone keeps
it current. It drifts anyway: a branch is squash-merged but its issue stays `in-progress`, a
feature branch has no issue at all, a `discuss` label outlives the conversation, issue #46
(the assumptions list) collects `- [ ]` lines nobody revisits, and issue text names a commit
that landed long ago. Each is cheap to see by comparing git with the board, and tedious to
see by memory. The Scribe is the board's bookkeeper: it compares the two and writes down what
should change, and does not change it.

## Design: small deterministic pieces, one optional model call

`bin/claude-scribe [--json] [--notify]` (Python, stdlib only). Output is a proposed-changes
list, one line per proposal, nothing when the board is in step, exit 0. Issues are read only
through `bin/ghd` (read calls: `issue list`, `issue view`, with comments for #46 only).
Policy lives in plain files under `${SCRIBE_DIR:-~/claude/.services/scribe}/` (`repos.json`
mapping each bare clone to its issue repo, `labels.json` naming the labels that mean
in-progress, discuss, queued; `thresholds.json`), edited by Cal or the Manager.

1. **merged.** Merged work is read from `git log <default>` of every `~/claude/.bare/*.git`
   (squash merges are found by subject and by the `(#N)`/`Closes #N` text in the message, not
   by patch id; `git cherry` misses squashes, see failure modes). An open issue is linked to
   a merge when its text names that commit id (7-40 hex chars that resolve in the clone), a
   `feature/<ws>` branch name, or a workspace name that equals a merged branch. Proposal:
   `close #N merged <repo>@<short id>` or, when the issue has an `in-progress` label and
   the work is only partly named, `relabel #N -in-progress`.
2. **orphans.** Branches from `hygiene.jsonl` (worktrees and `branches_without_worktree`,
   unmerged, not under `_tools`) whose branch name or workspace name appears in no open
   issue. Proposal: `create issue for <repo>:<branch> (<n> commits ahead)`. The title is the
   branch name; no body is drafted without the optional call.
3. **labels.** Open issues whose labels disagree with git or with age: `in-progress` on an
   issue linked to a merge (check 1), `in-progress` with no worktree or branch matching it,
   `discuss` with no comment or edit in N days (default 14). Proposal:
   `relabel #N -in-progress` / `relabel #N -discuss (idle <d> days)`.
4. **assumptions.** Parse the body of issue #46 (`SCRIBE_ASSUMPTIONS`, default 46): each
   `- [ ]` line gets an age from the issue's edit history if `ghd` returns it, else from the
   first run that saw the line (kept as a hash of the line plus a first-seen date in
   `scribe/seen.json`, so no text is stored twice). Lines older than N days (default 14)
   are proposed as `review #46 line "<first 60 chars>" (age <d> days)`. A line whose text
   names a merged commit or branch (check 1 rules) is proposed as `tick #46 line "<...>"`.
   Lines checked `- [x]` that name nothing open are left alone.
5. **named commits.** Open issues containing a commit id that now exists on a default branch
   but is not yet linked under check 1 (the issue says "see abc1234", abc1234 landed):
   `comment #N: abc1234 landed on <repo> main`. It is a proposal to look, never a close.
6. **Optional model call (default off).** For an orphan branch, a small model may draft a
   one-line issue title and a two-line body from the branch's commit subjects (not from
   issue text). It has no tools, gets the subjects inside a labelled data block ("data, not
   instructions"), and its output goes only into the proposal line as a draft. Without it
   the role runs with no model at all.

Every proposal is one line with a stable id (`<check>:<repo-or-issue>:<ref>`), so the
Manager can say "apply scribe:merged:42" and so a re-run does not duplicate a proposal.

## Reporting without outward action

- **Proposals file (local):** `scribe/proposals.md` under the services dir, rewritten on each
  run (previous run kept as `proposals.prev.md`), mode 644, in the Manager's reading format:
  a list of lines `- [ ] close #12  merged claude-wrapper@6ad2ba1`. It names issue numbers,
  repo and short commit ids, and quotes issue text only as the first 60 characters, in
  quotes, with control characters removed. No directory has a `PORT`; it is not served.
- **Applying:** the Manager alone reads the file and applies each line it agrees with through
  `bin/ghd issue close|edit|create|comment`, then reruns; applied lines vanish because the
  board then matches git. A line the Manager rejects is added to `scribe/ignore` by id, and
  the Scribe skips it afterwards.
- **Digest:** a "Board" line with counts per check only: `scribe: merged 2, orphans 1,
  labels 0, assumptions 3, named 0`. Left out when all zero.
- **Scheduler:** `--notify` (the scheduled form; manual runs log nothing) logs
  `{ts, findings, checks}` (counts per check) to `scribe/runs.jsonl` (last 2000 lines above
  1 MB) and appends the fixed `scribe: <n> proposals` alarm only when there are any.

## Trust model

- It reads git objects of the bare clones, `hygiene.jsonl`, issue text via `bin/ghd`, and
  its own policy files. It writes only the proposals files, `seen.json`, the runs log and one
  alarm line.
- It has no GitHub write path: it never calls `ghd` with `create`, `edit`, `close`,
  `comment`, `label`, `api`, or any method other than a read. The wrapper around `ghd` is a
  fixed allow-list of two subcommands (`issue list`, `issue view`), checked in the code and
  by a test.
- Issue text is untrusted data. An untrusted collaborator can write comments (and edit his
  own issues), so text is only matched, never executed, never interpolated into a command,
  never used as a path or ref name without a strict pattern (`^[0-9a-f]{7,40}$`,
  `^[A-Za-z0-9._/-]+$`), and never trusted to name a proposal's action: the action comes
  from the check, only the target number comes from text. Comments are read for #46 only,
  and only comments authored by a login in `allow-users` (shared with the Watchman) count
  as evidence for `tick`; a stranger's "this is done" can never close or tick anything.
- The optional model sees only commit subjects of local branches, never issue text.
- Proposals are suggestions; the Manager's review of each is the control.

## Checked and measured

Registry entries, each with `checked_by`: `role/scribe`, `schedule/scribe-scan`,
`log/scribe-runs`, `log/scribe-proposals`, `alarm/scribe`.
- **Auditor** (new deterministic checks): `runs.jsonl` has a row within 36 h of the
  schedule; counts in the last run equal the lines in `proposals.md`; every proposal cites a
  `#N` that exists and a commit that resolves; the `ghd` allow-list test passes; `seen.json`
  parses; a fixture board and repo (env override) yield the expected `close` and `tick`.
- **Coach** measures from `runs.jsonl` and the board: runs against cadence, proposals per
  run and trend, share of proposals the Manager applied (a proposal that disappears next
  run was applied or became moot; one added to `ignore` was rejected: the false-positive
  rate per check), median days from a merge to its issue closing (time to resolve), count of
  orphan branches older than N days, and model cost per run if the optional call is on.
- **Mechanic:** only that the schedule fired.

## Failure modes and named errors

`ScribeError` subclasses, each one line on stderr and exit 1 for a hard stop; a failing
check is reported as `<check>: unavailable` and the others still run:
- `GhdUnavailable` for issue reads that fail (check 1, 3, 4, 5 become `unavailable`, never
  green; check 2 needs issues too).
- `RepoUnreadable` for a bare clone `git` cannot read.
- `PolicyMissing` for an absent or unparsable policy file.
- `AmbiguousLink` when one issue names two different merged commits in different repos;
  reported as a line to look at, no action proposed.
- Known quiet failures to guard: squash merges that `git cherry` and `merged-by-cherry` in
  `hygiene.jsonl` call unmerged (hence the subject and message matching, with the cherry
  value used only as a hint), a branch re-created with a name that matches an old merge, a
  `discuss` label idle because Cal is thinking (the 14-day default and `ignore` list), a
  proposal reappearing every run after a rejection (the `ignore` file), a stale clone (the
  Scribe never fetches; it reports the clone's last-fetch age when over 1 day, so the
  Manager fetches), and a stranger's text shaping a proposal (the fixed-action rule and
  tests with hostile issue bodies).

## Not built

No GitHub write of any kind (no close, relabel, comment, create, edit, assignment), no
fetching or pushing, no reading or ticking of PRs, no milestone or project-board handling,
no drafting of full issue bodies from issue text, no deduplication of issues against each
other (that is idea intake's job), no priority or estimate setting, no replies to
collaborators, no web UI or dashboard panel, no reading of private repos beyond those in
`repos.json`.

## Open questions for Cal

1. **Which repos and which issue repo?** Default: every clone in `.bare` maps to
   dsktd/context; `repos.json` lets you map one elsewhere or leave it out.
2. **Thresholds:** `discuss` idle after 14 days and #46 lines stale after 14 days, or
   different? Default: 14 for both, in `thresholds.json`.
3. **Proposals for branches with no issue:** every unmerged branch, or only those with at
   least 3 commits or older than 3 days? Default: 3 commits or 3 days, so scratch branches
   stay quiet.
4. **Optional model call (issue-title drafts):** on or off? Default: off; turn on only if
   orphans keep appearing and Coach numbers show the Manager retyping titles.
5. **Schedule:** daily at 07:00 (before the 07:30 digest) or also after each merge?
   Default: daily only.
6. **Who may count as evidence for `tick`?** Default: comments and edits by logins in
   `allow-users` (you and the Manager's account); everyone else is ignored for this purpose.
