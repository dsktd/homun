#!/bin/sh
# fixes: d699d53 user channel: claim with markers in a role-writable user-state dir, the user box stays ro
# The role cannot write its own user box: the queue hook must still deliver the user's words.
set -eu
root=$1
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
chmod 755 "$tmp"
bus=$tmp/bus/manager
mkdir -p "$bus/user/host" "$bus/user-state" "$tmp/cal"
printf 'hello there' >"$bus/user/host/1700000000000000000"
printf 's1' >"$tmp/session"
cp "$root/container/cal-queue-hook.sh" "$tmp/hook.sh"
chmod -R a+rX "$tmp"
chown -R 65534 "$bus/user-state" "$tmp/cal"
out=$(printf '{"session_id":"s1"}' | setpriv --reuid=65534 --regid=65534 --clear-groups \
	env HOME="$tmp" HOMUN_BUS_DIR="$tmp/bus" CLAUDE_ROLE=manager CAL_CHANNEL_DIR="$tmp/cal" \
	MANAGER_SESSION_FILE="$tmp/session" PATH="$PATH" sh "$tmp/hook.sh")
case $out in *'hello there</channel>'*) ;; *) echo "not delivered from a read-only box: $out" >&2; exit 1 ;; esac
