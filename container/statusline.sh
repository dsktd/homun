#!/bin/sh
input=$(cat)
now=$(date +%s)

# Work in flight (claude-busy, cached 30 s so this never waits for it)
state=${CLAUDE_STATUS_STATE:-$HOME/.claude/usage}
busy_file=$state/busy.txt
if [ -x /usr/local/bin/claude-busy ] && { [ ! -e "$busy_file" ] || [ $((now - $(date -r "$busy_file" +%s 2>/dev/null || echo 0))) -gt 30 ]; }; then
	( mkdir -p "$state" && claude-busy >"$busy_file.tmp" 2>/dev/null; mv -f "$busy_file.tmp" "$busy_file" ) >/dev/null 2>&1 </dev/null &
fi
agents=$(grep -c . "$busy_file" 2>/dev/null)
# The busy count for other tools (claude-attach, the dashboard): ~/claude/.services/manager/busy holds
# N while claude-busy lists work, written atomically and only on change, and is gone at 0
if [ "${CLAUDE_ROLE:-manager}" = manager ]; then
	busy_out=${CLAUDE_BUSY_FILE:-$HOME/claude/.services/manager/busy}
	if [ "${agents:-0}" -gt 0 ]; then
		[ "$(cat "$busy_out" 2>/dev/null)" = "$agents" ] ||
			{ mkdir -p "${busy_out%/*}" && printf '%s\n' "$agents" >"$busy_out.tmp.$$" && mv -f "$busy_out.tmp.$$" "$busy_out"; } 2>/dev/null
	else
		rm -f "$busy_out"
	fi
	# The full claude-busy lines for the user's Emacs container (no claude-busy there): busy.txt keeps the
	# source's mtime and stays, empty, at 0, so a missing or old file means unknown, never idle
	if [ -e "$busy_file" ]; then
		cp -p "$busy_file" "${busy_out%/*}/busy.txt.tmp.$$" 2>/dev/null && mv -f "${busy_out%/*}/busy.txt.tmp.$$" "${busy_out%/*}/busy.txt"
	fi
fi

# The line itself is retired (blank); only the usage samples below remain
(
  dir=$HOME/.claude/usage
  sample=$(printf '%s' "$input" | jq -nrc --argjson now "$now" 'input | {
    ts: $now,
    session_id,
    model: .model.id,
    five_hour_used: .rate_limits.five_hour.used_percentage,
    five_hour_resets_at: .rate_limits.five_hour.resets_at,
    seven_day_used: .rate_limits.seven_day.used_percentage,
    seven_day_resets_at: .rate_limits.seven_day.resets_at,
    context_used_percentage: .context_window.used_percentage,
    context_window_size: .context_window.context_window_size,
    total_input_tokens: .context_window.total_input_tokens,
    total_output_tokens: .context_window.total_output_tokens,
    cost_usd: .cost.total_cost_usd,
    duration_ms: .cost.total_duration_ms,
    lines_added: .cost.total_lines_added,
    lines_removed: .cost.total_lines_removed,
    version,
    cwd
  } | "\(.session_id // "none" | gsub("[^A-Za-z0-9_-]"; "_")) \(.five_hour_used) \(.seven_day_used)", tojson') || exit
  key=${sample%%
*}
  sample=${sample#*
}

  state="$dir/${key%% *}"
  last=$(cat "$state" 2>/dev/null)
  [ "${last#* }" = "${key#* }" ] && [ $((now - ${last%% *})) -lt 60 ] && exit

  mkdir -p "$dir" &&
    { command -v flock >/dev/null && flock 9; printf '%s\n' "$sample" >&9; } 9>>"$HOME/.claude/usage.jsonl" &&
    printf '%s %s\n' "$now" "${key#* }" >"$state"
) >/dev/null 2>&1 </dev/null

exit 0
