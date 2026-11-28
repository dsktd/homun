#!/bin/sh
# Claude Code SessionStart hook (managed-settings.json): in a role's own claude only
# (start.sh sets CLAUDE_ROLE_PID to its own pid; CLAUDE_ROLE names the role, manager by default),
# pin the current session id in ~/.claude/<role>-session, so /clear, compaction or a fresh
# session cannot leave a stale pin. Other sessions do nothing.
role=${CLAUDE_ROLE:-manager}
sh /opt/homun/is-role.sh "$role" || exit 0
in=$(cat)
id=$(printf '%s' "$in" | jq -r '.session_id // empty' 2>/dev/null)
# Start-up timing (entrypoint.sh): on a start, compare this line with start.sh's `claude` line
# to see how long Claude Code took to bring the conversation up.
# (start.sh began that log when the role records its boots, `session.boot_record`)
[ ! -e "$HOME/claude/.services/$role/boot" ] || {
	printf '%s role-pin: session %s (%s)\n' "$(date +%s.%N | cut -c1-14)" \
		"$(printf '%s' "$in" | jq -r '.source // "?"' 2>/dev/null)" "$id" >>"$HOME/claude/.services/$role/start.log"
} 2>/dev/null
case $id in
'' | */* | .*) exit 0 ;;
esac
f=$HOME/.claude/$role-session
printf '%s\n' "$id" >"$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
exit 0
