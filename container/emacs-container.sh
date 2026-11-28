#!/usr/bin/env sh
# The command of the claude-emacs container (CLAUDE_ROLE=editor): starts the emacs service
# (container/services/emacs, which runs only here) under this container's runit and stays up
# as PID 1, showing its log.
export PATH=/nix/var/nix/profiles/emacs/bin:$PATH
log=$HOME/claude/.services/emacs/log
mkdir -p "$(dirname "$log")" && touch "$log"
claude-services start emacs || echo 'emacs-container: the emacs service did not start' >&2
# The remote cockpit's gateway, once a device was added (its `disabled` marker gone)
[ -e "$HOME/claude/.services/cockpit-gateway/disabled" ] || claude-services start cockpit-gateway >/dev/null 2>&1 &
# The phone notifier runs only here (its `only` file), where approvals can be answered
[ -e "$HOME/claude/.services/ntfy/disabled" ] || claude-services start ntfy >/dev/null 2>&1 &
exec tail -n 20 -F "$log"
