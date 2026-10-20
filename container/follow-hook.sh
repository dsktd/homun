#!/bin/sh
# Claude Code PostToolUse (Edit|Write|MultiEdit|NotebookEdit) and SessionEnd
# hook (managed-settings.json): record which file an agent just edited, for
# claude-follow in Emacs. One JSON line {ts, session_id, agent, agent_type, tool, file, cwd,
# worktree} is appended to $CLAUDE_FOLLOW_DIR/<session_id>.jsonl (default
# ~/claude/.services/follow); only the path and the tool, never file contents.
# SessionEnd deletes the session's file. No model call, and it never fails or
# blocks: every error ends in exit 0.
set -u
dir=${CLAUDE_FOLLOW_DIR:-$HOME/claude/.services/follow}

input=$(cat) || exit 0
id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
case $id in
'' | */* | .*) exit 0 ;;
esac

if [ "$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)" = SessionEnd ]; then
	rm -f -- "$dir/$id.jsonl"
	exit 0
fi

file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
[ -n "$file" ] || exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
case $file in
/*) ;;
*) file=${cwd:+$cwd/}$file ;;
esac
worktree=$(git -C "$(dirname -- "$file")" rev-parse --show-toplevel 2>/dev/null) || worktree=

mkdir -p -- "$dir" 2>/dev/null || exit 0
printf '%s' "$input" | jq -c --arg file "$file" --arg worktree "$worktree" --argjson ts "$(date +%s)" \
	'{ts: $ts, session_id, agent: (.agent_id // .agent_type // "main"), agent_type: (.agent_type // ""), tool: .tool_name, file: $file, cwd: (.cwd // ""), worktree: $worktree}' \
	>>"$dir/$id.jsonl" 2>/dev/null
exit 0
