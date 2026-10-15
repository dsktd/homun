FROM docker.io/debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
	curl bash nix-bin git ca-certificates libnotify-bin jq gh \
	&& rm -rf /var/lib/apt/lists/*
# Single-user nix as root: Debian's nix.conf references a nixbld group it never creates.
# Flakes replace channels: `nix shell nixpkgs#foo` resolves nixpkgs-unstable via the registry.
# No sandbox: builder namespaces generally aren't available inside a rootless container.
RUN mkdir -p /etc/nix && printf '%s\n' \
	'build-users-group =' \
	'experimental-features = nix-command flakes' \
	'sandbox = false' \
	>> /etc/nix/nix.conf
# System-level so it applies regardless of what's mounted at $HOME.
RUN printf '.claude/\n' > /etc/gitignore \
	&& git config --system core.excludesFile /etc/gitignore
# Let git authenticate to GitHub over HTTPS with gh's stored token (~/.config/gh, persisted by run.nu).
RUN git config --system credential.https://github.com.helper '!gh auth git-credential'

COPY ./entrypoint.sh /entrypoint.sh
COPY ./statusline.sh /statusline.sh
COPY ./managed-settings.json /etc/claude-code/managed-settings.json
ENTRYPOINT ["/entrypoint.sh"]
CMD ["claude"]
