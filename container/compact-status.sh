#!/bin/sh
# Claude Code PreCompact and SessionStart(compact) hook (managed-settings.json): keeps
# ~/claude/.services/compact/status, one JSON line {state, trigger, since}, for the Manager's
# compaction: `running` from PreCompact, `done` once the compacted session starts. The user's Emacs
# transcript shows it live; token counts and duration come from the transcript's compact_boundary.
# Always exits 0.
in=$(cat)
sh /opt/homun/is-role.sh primary || exit 0
case $(printf '%s' "$in" | jq -r .hook_event_name 2>/dev/null) in
PreCompact) state=running ;;
SessionStart) state=done ;;
*) exit 0 ;;
esac
trigger=$(printf '%s' "$in" | jq -r '.trigger // .source // ""' 2>/dev/null)
d=$HOME/claude/.services/compact
mkdir -p "$d" || exit 0
jq -cn --arg s "$state" --arg t "$trigger" --argjson e "$(date +%s)" \
	'{state: $s, trigger: $t, since: $e}' >"$d/status.tmp" 2>/dev/null && mv "$d/status.tmp" "$d/status"
exit 0
