#!/usr/bin/env sh
# The container's main process: open Claude on the screen the user was last
# typing in, so an update (Ctrl+Space U) comes back where it left off.
#
# Claude Code doesn't record which background job the fleet view is attached
# to, but history.jsonl logs every prompt with its session id, and a job's id
# is the first 8 characters of its session id. So: the last prompt's session is
# a job -> attach to it (the fleet view wakes it if it exited with the
# container); otherwise resume that conversation. Anything that fails falls
# through to the plain `claude --continue`.
history="$HOME/.claude/history.jsonl"
last=$(tail -n 1 "$history" 2>/dev/null | jq -r '.sessionId // empty' 2>/dev/null)
if [ -n "$last" ]; then
	job=$(printf '%.8s' "$last")
	if [ -f "$HOME/.claude/jobs/$job/state.json" ]; then
		# Left the job (Ctrl+Z or <-): carry on in the main conversation
		claude attach "$job" && exec claude --continue
	else
		claude --resume "$last" && exit
	fi
fi
claude --continue || exec claude
