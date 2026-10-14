#!/bin/sh
jq -r --argjson now "$(date +%s)" '
  def left: ([. - $now, 0] | max | floor) as $s
    | if $s >= 86400 then "\($s / 86400 | floor)d\($s % 86400 / 3600 | floor)h"
      else "\($s / 3600 | floor)h\($s % 3600 / 60 | floor)m" end;
  def window($name): select(.used_percentage != null)
    | "\($name) \([100 - .used_percentage, 0] | max | floor)%" + (if .resets_at then " ~\(.resets_at | left)" else "" end);

  [
    .model.display_name // empty,
    (.context_window.remaining_percentage // empty | "ctx \(floor)%"),
    (.rate_limits.five_hour // empty | window("5h")),
    (.rate_limits.seven_day // empty | window("7d"))
  ] | join(" | ")
'
