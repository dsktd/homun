#!/usr/bin/env sh
# The container's main process: open Claude on the screen the user was last
# typing in, so an update (Ctrl+Space U) comes back where it left off.
#
# This leans on Claude Code internals that its updater may change: history.jsonl
# logs every prompt with its session id, and a background job's id is the first
# 8 characters of its session id, with its state in ~/.claude/jobs/<id>/. If the
# last prompt went to a job, attach to it (the fleet view wakes it if it died
# with the container); otherwise resume that conversation. Whatever fails, or
# leaving the job (Ctrl+Z or <-), ends up in the plain `claude --continue`.
last=$(tail -n 1 "$HOME/.claude/history.jsonl" 2>/dev/null | jq -r '.sessionId // empty' 2>/dev/null)
if [ -n "$last" ]; then
	job=$(printf '%.8s' "$last")
	if [ -f "$HOME/.claude/jobs/$job/state.json" ]; then
		claude attach "$job"
	else
		claude --name Manager --resume "$last" && exit
	fi
fi
claude --name Manager --continue || exec claude --name Manager
