#!/usr/bin/env sh

# Claude Code is installed under the image's build-time HOME (/home); the
# runtime HOME is overridden to match the host, so use the absolute path.
export PATH="/home/.local/bin:$PATH"

exec "$@"
