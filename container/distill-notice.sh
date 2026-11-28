#!/bin/sh
# Claude Code SessionStart hook for /clear (managed-settings.json): in the Manager only,
# print one line naming the unreviewed distill proposals; Claude Code adds it to the context.
cat >/dev/null
sh /opt/homun/is-role.sh primary || exit 0
files=$(ls "$HOME"/claude/.services/distill/*.md 2>/dev/null | tr '\n' ' ')
[ -n "$files" ] || exit 0
echo "Distilled lessons from the last session await review (apply or discard each, then move the file to ~/claude/.services/distill/reviewed/): $files"
exit 0
