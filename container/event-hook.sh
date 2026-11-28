#!/bin/sh
# Claude Code hook for many events (managed-settings.json): appends one JSON line
# {ts, event, session, kind, summary} to ~/claude/.services/events/log.jsonl for the user's Emacs
# event log (claude-events.el). The Manager's main session only (subagent input is skipped,
# except SubagentStart/SubagentStop). summary is a tool name plus a 60-character hint, a
# notification message, a reason: never tool output, never more than 60 characters of a prompt.
# Rotates above 5 MB to log.jsonl.1. No output, always exits 0.
in=$(cat)
sh /opt/homun/is-role.sh primary || exit 0
d=$HOME/claude/.services/events
mkdir -p "$d" || exit 0
line=$(printf '%s' "$in" | jq -c --argjson ts "$(date +%s)" '
  def cut($n): tostring | gsub("[\\r\\n\\t]+"; " ") | .[0:$n];
  def hint: (.tool_input // {}) | (.command // .file_path // .pattern // .url // .description // .query // "") | cut(60);
  .hook_event_name as $e
  | select((.agent_id // "") == "" or $e == "SubagentStart" or $e == "SubagentStop")
  | { ts: $ts, event: $e, session: (.session_id // ""),
      kind: (.notification_type // .error // .source // .reason // .trigger // .agent_type // ""),
      summary: (
        if $e == "UserPromptSubmit" then (.prompt // "") | cut(60)
        elif $e == "PreToolUse" or $e == "PostToolUse" or $e == "PermissionRequest" then ((.tool_name // "") + " " + hint)
        elif $e == "PostToolUseFailure" then ((.tool_name // "") + " " + hint + " | " + ((.error // "") | cut(60)))
        elif $e == "Notification" then (.message // "") | cut(120)
        elif $e == "StopFailure" then (.last_assistant_message // .error_details // .error // "") | cut(120)
        elif $e == "SubagentStart" or $e == "SubagentStop" then ((.agent_type // "") + " " + (.agent_id // "")) | cut(60)
        else (.source // .reason // .trigger // "") end
      ) | sub("^ +"; "") }' 2>/dev/null) || exit 0
[ -n "$line" ] || exit 0
f=$d/log.jsonl
[ -f "$f" ] && [ "$(wc -c <"$f")" -gt 5242880 ] && mv "$f" "$f.1"
printf '%s\n' "$line" >>"$f"
exit 0
