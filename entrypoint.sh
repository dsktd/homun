#!/usr/bin/env sh

export PATH="$HOME/.local/bin:$PATH"

flock "$HOME/.local/share/claude/.install.lock" sh -c \
	'command -v claude >/dev/null 2>&1 || curl -fsSL https://claude.ai/install.sh | bash' || exit

# Shell panes open Nushell (bin/claude-container-shell). It lives in the persistent
# default profile (the claude-nix volume), so this only installs on the first start.
[ -x /nix/var/nix/profiles/default/bin/nu ] || nix profile install --profile /nix/var/nix/profiles/default nixpkgs#nushell

# ~/.gitconfig isn't persisted: author commits as the gh account unless the user set an identity.
# System-level, like the Containerfile's git config, so a mounted ~/.gitconfig still wins.
if ! git config user.name >/dev/null 2>&1; then
	login=$(gh config get -h github.com user 2>/dev/null) && [ -n "$login" ] && {
		git config --system user.name "$login"
		git config --system user.email "$login@users.noreply.github.com"
	}
fi

exec "$@"
