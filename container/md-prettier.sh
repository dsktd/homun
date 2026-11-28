#!/bin/sh
# PostToolUse: format the Markdown file the tool just wrote with prettier
f=$(jq -r '.tool_input.file_path // empty')
case $f in *.md) ;; *) exit 0 ;; esac
[ -f "$f" ] || exit 0
# prettier is in the default Nix profile (nix profile install nixpkgs#prettier);
# without it, fetch it once more through nix shell
set -- prettier --write --prose-wrap preserve --log-level warn "$f"
command -v prettier >/dev/null || set -- nix shell nixpkgs#prettier -c "$@"
"$@" >&2
exit 0
