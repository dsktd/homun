#!/bin/sh
# Claude Code SessionEnd and PreCompact hook (managed-settings.json): when the Manager's
# session ends by /clear or is about to be compacted, start distill.py on its transcript in the background (memory proposals
# for the manager to review) and return at once. Always exits 0.
in=$(cat)
sh /opt/homun/is-role.sh primary || exit 0
case $(printf '%s' "$in" | jq -r '"\(.hook_event_name) \(.reason // "")"' 2>/dev/null) in
'SessionEnd clear' | 'PreCompact '*) ;;
*) exit 0 ;;
esac
t=$(printf '%s' "$in" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -f "$t" ] || exit 0
d=$HOME/claude/.services/distill
mkdir -p "$d" || exit 0
setsid -f python3 /opt/homun/distill.py "$t" </dev/null >>"$d/log" 2>&1
exit 0
