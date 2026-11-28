#!/bin/sh
# fixes: 59d0667 busy-status: ignore a subagent's hook events
# A subagent's tool call after the turn's Stop must not set the status back to busy.
set -eu
root=$1
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '#!/bin/sh\nexit 0\n' >"$tmp/is-role.sh"
sed "s#/opt/homun/is-role.sh#$tmp/is-role.sh#" "$root/container/busy-status.sh" >"$tmp/busy-status.sh"
hook() { printf '%s' "$1" | HOME=$tmp/home sh "$tmp/busy-status.sh"; }
hook '{"hook_event_name":"UserPromptSubmit","session_id":"s"}'
hook '{"hook_event_name":"Stop","session_id":"s"}'
hook '{"hook_event_name":"PreToolUse","session_id":"s","agent_id":"a1","tool_name":"Bash"}'
state=$(jq -r .state "$tmp/home/claude/.services/busy/status")
[ "$state" = idle ] || { echo "status is $state after a subagent's tool call" >&2; exit 1; }
