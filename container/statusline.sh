#!/bin/sh
input=$(cat)
now=$(date +%s)

# Resource mode: the usage-db service writes "<mode> <override|-> <epoch> <slots>" (no Python per refresh);
# a file older than 30 minutes is a stopped service and shows nothing
mode=
slots=
{ read -r m o t s <"${USAGE_MODE_FILE:-$HOME/claude/.services/usage-db/mode}" &&
	[ $((now - ${t:-0})) -lt 1800 ] && mode="$m${o#-}" slots=$s; } 2>/dev/null

# What is relevant right now, shown only when it is: work in flight (claude-busy, cached 30 s so the
# status line never waits for it), questions waiting for the user (claude-question's pending files)
# and the API credit while a worker is running or has spent today
state=${CLAUDE_STATUS_STATE:-$HOME/.claude/usage}
busy_file=$state/busy.txt
if [ -x /usr/local/bin/claude-busy ] && { [ ! -e "$busy_file" ] || [ $((now - $(date -r "$busy_file" +%s 2>/dev/null || echo 0))) -gt 30 ]; }; then
	( mkdir -p "$state" && claude-busy >"$busy_file.tmp" 2>/dev/null; mv -f "$busy_file.tmp" "$busy_file" ) >/dev/null 2>&1 </dev/null &
fi
agents=$(grep -c . "$busy_file" 2>/dev/null)
workers=$(grep -c '^worker ' "$busy_file" 2>/dev/null)
questions=$(ls "${CLAUDE_QUESTIONS_DIR:-$HOME/claude/.services/ask}/pending" 2>/dev/null | grep -c '\.json$')
credit=
if [ "${workers:-0}" -gt 0 ]; then
	credit=$(jq -r 'if .remaining then (.remaining * 100 | round / 100 | tostring) else empty end' "${CLAUDE_WORKER_DIR:-$HOME/claude/.services/workers}/balance.json" 2>/dev/null)
fi

# The badge says "manager" only for the pinned Manager session; any other session
# (agents) shows its own name
pinned=$(cat "${MANAGER_SESSION_FILE:-$HOME/.claude/manager-session}" 2>/dev/null)

printf '%s' "$input" | jq -r --argjson now "$now" --arg mode "$mode" --arg slots "$slots" --arg pinned "$pinned" --arg agents "${agents:-0}" --arg questions "${questions:-0}" --arg credit "$credit" '
  def esc: "\u001b[";
  def rgb($r; $g; $b): esc + "38;2;\($r);\($g);\($b)m";
  def paint($c): $c + . + esc + "0m";
  def dim: rgb(120; 125; 140);
  # Colour by how much is left: green, yellow, red
  def level: if . >= 50 then rgb(95; 200; 130) elif . >= 20 then rgb(240; 200; 90) else rgb(240; 95; 95) end;
  def left: ([. - $now, 0] | max | floor) as $s
    | if $s >= 86400 then "\($s / 86400 | floor)d\($s % 86400 / 3600 | floor)h"
      else "\($s / 3600 | floor)h\($s % 3600 / 60 | floor)m" end;
  def pct($name): ([100 - ., 0] | max | floor) as $p | "\($name) \($p)%" | paint($p | level);
  def window($name): select(.used_percentage != null)
    | (.used_percentage | pct($name)) + (if .resets_at then (" ~\(.resets_at | left)" | paint(dim)) else "" end);

  def badge: {burn: "🔥 burn", normal: "normal", frugal: "🧊 frugal", hold: "⏸ hold"} as $b
    | ($mode | sub("override$"; "")) as $m
    | if $b[$m] then $b[$m] + (if $mode | endswith("override") then "*" else "" end) | paint(rgb(200; 170; 255)) else empty end;
  def slotbadge: if $slots != "" then "slots \($slots)" | paint(rgb(200; 170; 255)) else empty end;

  # Only the Manager own status line carries the Manager context
  def mine: $pinned == "" or .session_id == $pinned;
  def agentsbadge: if mine and ($agents | tonumber) > 0 then "⚙ \($agents) running" | paint(rgb(110; 200; 230)) else empty end;
  def questionsbadge: if mine and ($questions | tonumber) > 0 then "❓ \($questions) for you" | paint(rgb(240; 200; 90)) else empty end;
  def creditbadge: if mine and $credit != "" then "API $\($credit)" | paint(rgb(95; 200; 130)) else empty end;

  def who: if $pinned != "" and .session_id != $pinned then "🤖 " + (.session_name // "agent") else "🧮 Tally" end;

  # the Tally nameplate is yellow; any other session keeps the blue one
  (if mine then esc + "1;38;2;40;32;0;48;2;240;200;90m " else esc + "1;38;2;255;255;255;48;2;60;90;200m " end) + who + " " + esc + "0m " + ([
    questionsbadge,
    agentsbadge,
    creditbadge,
    badge,
    slotbadge,
    (.model.display_name // empty | paint(rgb(110; 200; 230))),
    (.context_window.remaining_percentage // empty | (100 - .) | pct("ctx")),
    (.rate_limits.five_hour // empty | window("5h")),
    (.rate_limits.seven_day // empty | window("7d"))
  ] | join(" | " | paint(dim)))
'
status=$?

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

exit $status
