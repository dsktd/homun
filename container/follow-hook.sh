#!/bin/sh
# Claude Code PostToolUse (Edit|Write|MultiEdit|NotebookEdit|Bash), SubagentStop
# and SessionEnd hook (managed-settings.json): record which file an agent just edited, for
# claude-follow in Emacs. One JSON line {ts, session_id, agent, agent_type, tool, file, cwd,
# worktree} is appended to $CLAUDE_FOLLOW_DIR/<session_id>.jsonl (default
# ~/claude/.services/follow); only the path and the tool, never file contents.
# SubagentStop appends a marker row (tool "done", empty file and worktree) for the
# finished subagent; the Manager's own Stop is not hooked. SessionEnd moves the
# session's file to $CLAUDE_FOLLOW_DIR/archive/ (what claude-follow shows as
# archived) and deletes archived logs not written for more than 7 days. No model call, and it never fails or
# blocks: every error ends in exit 0.
set -u
dir=${CLAUDE_FOLLOW_DIR:-$HOME/claude/.services/follow}

input=$(cat) || exit 0
id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
case $id in
'' | */* | .*) exit 0 ;;
esac

if [ "$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)" = SessionEnd ]; then
	mkdir -p -- "$dir/archive" 2>/dev/null && mv -f -- "$dir/$id.jsonl" "$dir/archive/$id.jsonl" 2>/dev/null
	find "$dir/archive" -type f -name '*.jsonl' -mtime +7 -delete 2>/dev/null
	exit 0
fi

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
now=$(date +%s)

# Append one row for FILE in WORKTREE made by TOOL; COMMIT, when not empty,
# is the commit that changed it.
log_row() { # file worktree tool commit
	printf '%s' "$input" | jq -c --arg file "$1" --arg worktree "$2" --arg tool "$3" --arg commit "$4" --argjson ts "$now" \
		'{ts: $ts, session_id, agent: (.agent_id // .agent_type // "main"), agent_type: (.agent_type // ""), tool: $tool, file: $file, cwd: (.cwd // ""), worktree: $worktree}
		 + (if $commit == "" then {} else {commit: $commit} end)' \
		>>"$dir/$id.jsonl" 2>/dev/null
}

if [ "$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)" = SubagentStop ]; then
	mkdir -p -- "$dir" 2>/dev/null || exit 0
	log_row "" "" "done" ""
	exit 0
fi

# Bash edits are invisible to the edit tools' hook, so after a command that can
# move a branch (git commit, merge, revert, cherry-pick, rebase, am) look at
# every worktree under $CLAUDE_FOLLOW_ROOT (default ~/claude, two levels down)
# and log, as tool "commit", the files whose HEAD moved since the last look.
# The first look only records the heads, except a HEAD commit under a minute old.
if [ "$tool" = Bash ]; then
	cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
	case $cmd in
	*git*commit* | *git*merge* | *git*revert* | *git*cherry-pick* | *git*rebase* | *git*' am'*) ;;
	*) exit 0 ;;
	esac
	root=${CLAUDE_FOLLOW_ROOT:-$HOME/claude}
	state=$dir/.heads
	mkdir -p -- "$dir" 2>/dev/null || exit 0
	[ -f "$state" ] || : >"$state" 2>/dev/null || exit 0
	for wt in "$root"/*/*/; do
		wt=${wt%/}
		[ -e "$wt/.git" ] || continue
		head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || continue
		old=$(grep -F -- "$wt " "$state" | tail -n 1 | cut -d' ' -f2)
		[ "$old" = "$head" ] && continue
		# A worktree seen for the first time: log its HEAD commit only when it is
		# under a minute old (a new worktree's first commit)
		if [ -z "$old" ]; then
			made=$(git -C "$wt" log -1 --format=%ct HEAD 2>/dev/null) || made=0
			if [ $((now - made)) -lt 60 ]; then
				old=$(git -C "$wt" rev-parse -q --verify HEAD~1 2>/dev/null) || old=
			fi
		fi
		if [ -n "$old" ]; then
			git -C "$wt" diff --name-only "$old" "$head" 2>/dev/null | head -n 50 | while IFS= read -r name; do
				log_row "$wt/$name" "$wt" commit "$head"
			done
		fi
		{ grep -vF -- "$wt " "$state"; printf '%s %s\n' "$wt" "$head"; } >"$state.new" 2>/dev/null && mv -f -- "$state.new" "$state"
	done
	exit 0
fi

file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
[ -n "$file" ] || exit 0
case $file in
/*) ;;
*) file=${cwd:+$cwd/}$file ;;
esac
worktree=$(git -C "$(dirname -- "$file")" rev-parse --show-toplevel 2>/dev/null) || worktree=

mkdir -p -- "$dir" 2>/dev/null || exit 0
log_row "$file" "$worktree" "$tool" ""
exit 0
