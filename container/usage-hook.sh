#!/bin/sh
# Claude Code Stop, SubagentStop and SessionEnd hook (managed-settings.json):
# import the transcript that just grew into the usage-db's usage.sqlite, so
# costs are current as soon as a turn ends instead of at the service's next
# 5-minute import. The hook input (JSON on stdin) names the file: the subagent's
# own transcript on SubagentStop, the session's otherwise. The import runs in
# the background so Claude is never held up, one at a time under the lock the
# service's import takes too, logging to the service's log. It reads only what
# was appended since the last import, so running it on every turn is cheap.
# Nothing happens until the service has created the database.
set -u
dir=${CLAUDE_USAGE_DB_DIR:-$HOME/claude/.services/usage-db}
import=${CLAUDE_USAGE_IMPORT:-/opt/homun/services/usage-db/import.nu}
db=$dir/usage.sqlite

file=$(jq -r '.agent_transcript_path // .transcript_path // empty' 2>&1) || { echo "usage-hook: unreadable hook input: $file" >>"$dir/log"; exit 0; }
[ -n "$file" ] && [ -f "$file" ] && [ -f "$db" ] || exit 0
(
	flock 9
	nu "$import" transcript "$file" "$db" || echo "usage-hook: import of $file failed"
) 9>>"$db.lock" >>"$dir/log" 2>&1 </dev/null &
exit 0
