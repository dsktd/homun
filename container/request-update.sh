#!/usr/bin/env sh
# Ask the host to rebuild and recreate this container, the same as Ctrl+Space U,
# from inside it: mark start.sh (PID 1) with SIGUSR1, then stop everything else
# in the container, including the Claude it is running, so it exits 75 and
# claude-attach on the host takes over. Background jobs are woken again on
# reattach. This script usually runs from inside that Claude and so does not
# outlive the second kill, which spares PID 1 and this process only.
#
# Until entrypoint.sh has handed over to start.sh (installing Claude Code on a
# first start) there is no trap to mark: refuse rather than kill the installer.
set -- $(tr '\0' ' ' < /proc/1/cmdline)
case "${2:-}" in
	*start.sh) ;;
	*) echo "The container is still starting (PID 1 is $*); try again shortly" >&2; exit 1 ;;
esac
kill -USR1 1 && kill -TERM -1
