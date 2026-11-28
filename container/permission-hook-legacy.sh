#!/bin/sh
# Claude Code PermissionRequest hook (managed-settings.json): lets the user answer the Manager's permission
# prompts from their Emacs transcript. The Manager's session and its subagents (not other roles).
# Writes ~/claude/.services/approve/requests/<id>.json {id, tool, summary, input, agent, since, timeout}
# (temp + rename; `input` is the tool input cut to 4000 characters, `agent` {id, type} for a subagent's
# prompt, else null), then waits up to $APPROVE_TIMEOUT seconds (default 60) for approve/answers/<id>
# holding `allow`, `deny` or {"behavior":"deny","message":REASON}, and prints the decision. No answer in time, or anything else wrong: no
# output, exit 0, so the normal terminal prompt appears. A hook that is killed removes its request too. The answers directory is read-only in every container but the editor's
# (run.nu mounts it so), so only the user's Emacs can write an answer; see docs/development.md.
in=$(cat)
sh /opt/homun/is-role.sh primary || exit 0
# A headless session's prompts are answered by its broker (session-broker), through the same card
[ -z "${HOMUN_HEADLESS:-}" ] || exit 0
d=${APPROVE_DIR:-$HOME/claude/.services/approve}
mkdir -p "$d/requests" "$d/answers" 2>/dev/null || exit 0
id=$(date +%s%N)-$$
req=$d/requests/$id.json
trap 'rm -f "$req" "$req.tmp"' EXIT
trap 'exit 0' TERM INT HUP
t=${APPROVE_TIMEOUT:-60}
printf '%s' "$in" | jq -c --arg id "$id" --argjson now "$(date +%s)" --argjson timeout "$t" '
	(.tool_input // {}) as $i
	| {id: $id, tool: (.tool_name // "?"),
	   summary: (($i.command // $i.file_path // $i.url // $i.pattern // ($i | tostring)) | tostring | .[0:400]),
	   input: ($i | if type == "object" then map_values(if type == "string" then .[0:4000] else . end) else {} end
	           | if (tostring | length) > 6000 then {} else . end),
	   agent: (if (.agent_id // "") != "" then {id: .agent_id, type: (.agent_type // "")} else null end),
	   since: $now, timeout: $timeout}' >"$req.tmp" 2>/dev/null && mv "$req.tmp" "$req" || exit 0
n=$((t * 2))
while [ "$n" -gt 0 ]; do
	if [ -f "$d/answers/$id" ]; then
		a=$(head -c 4000 "$d/answers/$id" 2>/dev/null)
		case $a in
		allow | deny)
			jq -cn --arg b "$a" '{hookSpecificOutput: {hookEventName: "PermissionRequest",
				decision: ({behavior: $b} + (if $b == "deny" then {message: "The user denied this in Emacs"} else {} end))}}'
			exit 0 ;;
		'{"behavior":"deny"'*)
			# a denial with the user's reason (the phone's Deny…)
			printf '%s' "$a" | jq -c '{hookSpecificOutput: {hookEventName: "PermissionRequest",
				decision: {behavior: "deny", message: ("The user denied this: " + (.message // "" | tostring | .[0:1000]))}}}' && exit 0 ;;
		esac
	fi
	sleep 0.5
	n=$((n - 1))
done
exit 0
