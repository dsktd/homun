#!/usr/bin/env sh

export PATH="$HOME/.local/bin:$PATH"

flock "$HOME/.local/share/claude/.install.lock" sh -c \
	'command -v claude >/dev/null 2>&1 || curl -fsSL https://claude.ai/install.sh | bash' || exit

# Shell panes open Nushell (claude-container-shell). It lives in the persistent
# default profile (the claude-nix volume), so this only installs on the first start.
nu=/nix/var/nix/profiles/default/bin/nu
[ -x "$nu" ] || nix profile install --profile /nix/var/nix/profiles/default nixpkgs#nushell
[ -x "$nu" ] && usermod -s "$nu" root

# ~/.gitconfig isn't persisted: author commits as the gh account unless the user set an identity.
if ! git config --global user.name >/dev/null 2>&1; then
	login=$(gh api user -q .login 2>/dev/null) && {
		git config --global user.name "$login"
		git config --global user.email "$login@users.noreply.github.com"
	}
fi

exec "$@"
