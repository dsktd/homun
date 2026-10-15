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
#
# A session id in ~/.claude/manager-session pins the Manager: it is opened
# instead of the last-used one, so a stray `/clear` or second session in
# ~/claude cannot take its place.
#
# An update can also be requested from inside the container (request-update.sh):
# it sends SIGUSR1 here and stops the running Claude, and we exit 75 instead of
# starting another; claude-attach on the host reads that code and runs
# claude-update. The shell runs the trap once the foreground Claude has
# returned (at once, if nothing is running), which is when we want to act.
trap 'exit 75' USR1

last=$(cat "$HOME/.claude/manager-session" 2>/dev/null)
[ -n "$last" ] || last=$(tail -n 1 "$HOME/.claude/history.jsonl" 2>/dev/null | jq -r '.sessionId // empty' 2>/dev/null)
if [ -n "$last" ]; then
	job=$(printf '%.8s' "$last")
	if [ -f "$HOME/.claude/jobs/$job/state.json" ]; then
		claude attach "$job"
	else
		claude --name Manager --resume "$last" && exit
	fi
fi
claude --name Manager --continue || claude --name Manager
