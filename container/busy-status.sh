#!/bin/sh
# Claude Code UserPromptSubmit, PreToolUse, PostToolUse and Stop hook (managed-settings.json): keeps
# ~/claude/.services/busy/status, one JSON line {state, tool, since, tool_since}, for the Manager:
# `busy` from a prompt or tool call (since = turn start, tool = the running tool, empty between
# tools), `idle` at Stop. The user's Emacs transcript shows it live. Always exits 0.
# A subagent's tool calls fire these hooks in the same session with agent_id set; they are not
# the session's turn, and its Stop never comes for them, so they would leave `busy` standing
# after the turn ended and hold the user channel's queue (scheduler-go/user.go) for good.
in=$(cat)
sh /opt/homun/is-role.sh primary || exit 0
[ -n "$(printf '%s' "$in" | jq -r '.agent_id // ""' 2>/dev/null)" ] && exit 0
ev=$(printf '%s' "$in" | jq -r .hook_event_name 2>/dev/null)
d=$HOME/claude/.services/busy
mkdir -p "$d" || exit 0
now=$(date +%s)
since=$now
if [ "$ev" != UserPromptSubmit ] && [ "$ev" != Stop ]; then
	old=$(jq -r 'select(.state == "busy") | .since' "$d/status" 2>/dev/null)
	[ -n "$old" ] && since=$old
fi
case $ev in
UserPromptSubmit) state=busy tool= ;;
PreToolUse) state=busy tool=$(printf '%s' "$in" | jq -r '.tool_name // ""') ;;
PostToolUse) state=busy tool= ;;
Stop) state=idle tool= ;;
*) exit 0 ;;
esac
jq -cn --arg s "$state" --arg t "$tool" --argjson e "$since" --argjson n "$now" \
	'{state: $s, tool: $t, since: $e, tool_since: $n}' >"$d/status.tmp" 2>/dev/null && mv "$d/status.tmp" "$d/status"
exit 0
