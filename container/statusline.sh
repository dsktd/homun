#!/bin/sh
input=$(cat)
now=$(date +%s)

printf '%s' "$input" | jq -r --argjson now "$now" '
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

  esc + "1;38;2;255;255;255;48;2;60;90;200m 🤖 manager " + esc + "0m " + ([
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
