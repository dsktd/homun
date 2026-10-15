#!/usr/bin/env sh

export PATH="$HOME/.local/bin:$PATH"

flock "$HOME/.local/share/claude/.install.lock" sh -c \
	'command -v claude >/dev/null 2>&1 || curl -fsSL https://claude.ai/install.sh | bash' || exit

exec "$@"
