#!/bin/sh
# Claude Code PostToolUse hook (managed-settings.json): hand the Manager the messages the user queued
# in Emacs. New path first (stage 5): every bus/<role>/user/<device>/<ns> file (that box is
# read-only here) without a marker in bus/<role>/user-state/<device>/{sending,claimed,failed}/ is
# claimed by creating its sending/ marker with noclobber (the user channel server claims the same
# way while idle), logged to user-state/log.jsonl, printed as <channel source="user" device="..."
# ts="..."> and marked claimed/, unless user-state/<device>/paused holds it (stale after 30
# minutes). A marker that cannot be made for any other reason than an existing one is reported in
# the output, never skipped in silence. Then the old queue, one release: Only for the Manager's session (id in ~/.claude/manager-session). Every file in
# $CAL_CHANNEL_DIR/queue (default ~/claude/.services/cal/queue, written by claude-compose.el) is
# claimed by moving it into queue/claimed/ (Emacs claims the same way, into queue/sending/, so a
# message goes out once), appended to the channel audit log cal/log.jsonl, and printed as
# additionalContext made of <channel source="cal" ts="..."> blocks.
# While $q/paused exists (a message failed in Emacs and waits for retry or drop, so nothing may
# overtake it) nothing is delivered, unless it is older than 30 minutes.
# Empty queue or another session: no output. It never fails or blocks: every error ends in exit 0.
# The socket is not touched (only the user's Emacs writes there); Emacs delivers what is left over the
# channel once the turn has ended.
set -u
dir=${CAL_CHANNEL_DIR:-$HOME/claude/.services/cal}
q=$dir/queue
want=$(cat "${MANAGER_SESSION_FILE:-$HOME/.claude/manager-session}" 2>/dev/null) || exit 0
[ -n "$want" ] || exit 0
# A subagent shares the Manager's session_id but its hook input carries agent_id: deliver only
# in the Manager's own main session, or the subagent would swallow the message.
ids=$(jq -r '[.session_id // "", .agent_id // ""] | @tsv' 2>/dev/null) || exit 0
id=${ids%%	*}
agent=${ids#*	}
[ -z "$agent" ] || exit 0
[ "$id" = "$want" ] || exit 0

out=
bus=${HOMUN_BUS_DIR:-$HOME/claude/.services/bus}/${CLAUDE_ROLE:-manager}
for d in "$bus"/user/*/; do
	[ -d "$d" ] || continue
	d=${d%/}
	dev=${d##*/}
	case $dev in *[!a-z0-9-]* | -* | '') continue ;; esac
	s=$bus/user-state/$dev
	if [ -e "$s/paused" ]; then
		[ -z "$(find "$s/paused" -mmin +30 2>/dev/null)" ] && continue
		rm -f "$s/paused"
		jq -nc --arg d "$dev" '{time:(now|strftime("%Y-%m-%dT%H:%M:%SZ")),device:$d,note:"stale pause ignored"}' >>"$bus/user-state/log.jsonl" 2>/dev/null
	fi
	for f in "$d"/[0-9]*; do
		[ -f "$f" ] || continue
		name=${f##*/}
		[ -e "$s/claimed/$name" ] || [ -e "$s/failed/$name" ] || [ -e "$s/sending/$name" ] && continue
		if ! err=$(mkdir -p "$s/sending" "$s/claimed" 2>&1 && (set -C && : >"$s/sending/$name") 2>&1); then
			[ -e "$s/sending/$name" ] && continue # another reader took it
			out="${out}homun queue hook error, not the user's words: cannot claim user message $dev/$name: $err
"
			continue
		fi
		text=$(cat "$f")
		jq -nc --arg first "$(printf '%s' "$text" | sed -n '1{s/^[[:space:]]*//;p;q}' | cut -c1-200)" \
			--argjson size "$(wc -c <"$f")" --arg sha "$(sha256sum <"$f" | cut -d' ' -f1)" --arg d "$dev" --arg id "$name" \
			'{first:$first,sha256:$sha,size:$size,device:$d,id:$id,time:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}' \
			>>"$bus/user-state/log.jsonl" 2>/dev/null
		out="$out<channel source=\"user\" device=\"$dev\" ts=\"$(printf '%s' "$name" | cut -c1-10)\">$text</channel>
"
		mv "$s/sending/$name" "$s/claimed/$name" 2>/dev/null
	done
done

if [ -e "$q/paused" ]; then
	# a pause older than 30 minutes is stale (Emacs died mid-edit): ignore it, say so in the log
	if [ -n "$(find "$q/paused" -mmin +30 2>/dev/null)" ]; then
		rm -f "$q/paused"
		jq -nc '{time:(now|strftime("%Y-%m-%dT%H:%M:%SZ")),note:"stale pause ignored"}' >>"$dir/log.jsonl" 2>/dev/null
	fi
fi
[ -e "$q/paused" ] || mkdir -p "$q/claimed" 2>/dev/null
for f in "$q"/[0-9]*; do
	[ -e "$q/paused" ] && break
	[ -f "$f" ] || continue
	name=${f##*/}
	c=$q/claimed/$name
	mv "$f" "$c" 2>/dev/null || continue
	ts=$(printf '%s' "$name" | cut -c1-10)
	text=$(cat "$c")
	size=$(wc -c <"$c")
	sha=$(sha256sum <"$c" | cut -d' ' -f1)
	jq -nc --arg first "$(printf '%s' "$text" | sed -n '1{s/^[[:space:]]*//;p;q}' | cut -c1-200)" \
		--argjson size "$size" --arg sha "$sha" \
		'{first:$first,sha256:$sha,size:$size,time:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}' \
		>>"$dir/log.jsonl" 2>/dev/null
	out="$out<channel source=\"cal\" ts=\"$ts\">$text</channel>
"
	rm -f "$c"
done
[ -n "$out" ] || exit 0
jq -nc --arg c "$out" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}' 2>/dev/null
exit 0
