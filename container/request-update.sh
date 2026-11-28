#!/usr/bin/env sh
# Ask the host to recreate this container on its current image, from inside it: mark start.sh
# (PID 1) with SIGUSR1, then stop everything else in the container, including the Claude it is
# running, so it exits 75 and claude-attach on the host takes over (`claude-update recreate`).
# Background jobs are woken again on reattach. This script usually runs from inside that Claude
# and so does not outlive the second kill, which spares PID 1 and this process only.
#
# It writes no request file: the signal and the exit code are the request. It brings no new code
# and builds nothing: the launcher is updated by a home-manager switch on the host, whose host
# service (homun-host) builds the image and rolls the containers itself. Only an image such a switch
# built while work was running here (an `update-ready` alarm) is taken by this recreate.
#
# Work in progress (claude-busy: running background agents, claude-worker runs)
# stops it unless called with --force, which skips that check.
#
# The mechanic must answer a hello first (below), unless --force.
#
# Until entrypoint.sh has handed over to start.sh (installing Claude Code on a
# first start) there is no trap to mark: refuse rather than kill the installer.
force=
for a; do
	case "$a" in
		--force|-f|force) force=--force ;;
		full) echo "request-update.sh no longer updates: a home-manager switch on the host does; without arguments it recreates this container" >&2; exit 2 ;;
		*) echo "usage: request-update.sh [force|-f|--force]" >&2; exit 2 ;;
	esac
done
set -- $(tr '\0' ' ' < /proc/1/cmdline)
case "${2:-}" in
	*start.sh) ;;
	*) echo "The container is still starting (PID 1 is $*); try again shortly" >&2; exit 1 ;;
esac
# Debounce: a container that began under 60 s ago is still starting (its Claude has not opened
# the conversation yet, and killing it only restarts the whole start); force skips this.
if [ "$force" != --force ]; then
	up=$(( $(date +%s) - $(stat -c %Y /proc/1 2>/dev/null || date +%s) ))
	if [ "$up" -lt 60 ]; then
		echo "This container started ${up}s ago and is still starting; not recreating again (wait ~$((60 - up))s, or run again with --force)" >&2
		exit 1
	fi
fi
if [ "$force" != --force ] && command -v claude-busy >/dev/null; then
	# exit 1 with no output is a crashed probe (a traceback), not work in progress
	if work=$(claude-busy) || [ -z "$work" ]; then :; else
		printf '%s\n' "$work" "Work is in progress; run again with --force to recreate anyway" >&2
		exit 1
	fi
fi
# The repair crew must be there before this container goes down: the mechanic's watch answers a
# hello file within its 10 s pass with its session heartbeat's age
#. Skipped where no mechanic has ever run; --force overrides and says so.
mech=$HOME/claude/.services/mechanic
if [ -e "$mech/heartbeat" ]; then
	if [ "$force" = --force ]; then
		echo "force: recreating without the mechanic's hello" >&2
	else
		hello=$mech/hello/$(date +%s)-$$
		mkdir -p "$mech/hello" && date +%s >"$hello"
		n=0
		while [ ! -e "$hello.reply" ] && [ "$n" -lt 20 ]; do sleep 1; n=$((n + 1)); done
		age=$(jq -r 'select(.role == "mechanic") | .session_age // empty' "$hello.reply" 2>/dev/null)
		rm -f "$hello" "$hello.reply"
		case "$age" in '' | *[!0-9]*) age=-1 ;; esac
		if [ "$age" -lt 0 ] || [ "$age" -gt 600 ]; then
			echo "The mechanic did not answer its hello (no reply in 20 s, or its session heartbeat is stale): not recreating. Run again with --force to recreate anyway" >&2
			exit 1
		fi
	fi
fi
kill -USR1 1 && kill -TERM -1
