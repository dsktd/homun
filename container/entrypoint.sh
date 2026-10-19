#!/usr/bin/env sh

export PATH="$HOME/.local/bin:$PATH"

flock "$HOME/.local/share/claude/.install.lock" sh -c \
	'command -v claude >/dev/null 2>&1 || curl -fsSL https://claude.ai/install.sh | bash' || exit

# Earlier images installed Nushell into the claude-nix volume, where it shadows the
# image's pinned copy on PATH; remove it once.
[ -e /nix/var/nix/profiles/default/bin/nu ] && nix profile remove --profile /nix/var/nix/profiles/default nushell >/dev/null 2>&1

# Seed the persisted global config (~/.config/git, mounted by run.nu; git uses it
# while ~/.gitconfig is absent) with the gh account as the
# commit identity whenever the global config has no user.name (so on first
# start, or after the user removes it); whatever the user sets stays.
if ! git config --global user.name >/dev/null 2>&1; then
	login=$(gh config get -h github.com user 2>/dev/null) && [ -n "$login" ] && {
		git config --global user.name "$login"
		git config --global user.email "$login@users.noreply.github.com"
	}
fi

# Services under ~/claude/.services (see services.sh): refresh the ones shipped
# with the wrapper, then start every enabled one (the first start also starts runit's runsvdir).
claude-services install-bundled
claude-services start-all || echo 'claude-services: some services failed to start' >&2

exec "$@"
