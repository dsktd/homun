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
ENV PATH=/nix/var/nix/profiles/default/bin:$PATH
# Nushell is the shell of every pane (bin/claude-container-shell). It comes from the
# static musl release tarball rather than nix: /nix is the claude-nix volume at runtime,
# so anything the image puts there is hidden. Pinned; bump the version and both digests
# together (gh api repos/nushell/nushell/releases/tags/<ver> -q '.assets[] | .name + " " + .digest', bare hex).
ARG TARGETARCH
ARG NU_VERSION=0.116.0
ARG NU_SHA256_AMD64=7b91aeef575080f4b90405ba4512f4ccd0c21a6fbcd99f18bde3272c75213f00
ARG NU_SHA256_ARM64=bc3503d0588caa7c2835d61337825152141c748c126817739cb86519c593416e
RUN set -eu; \
	case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
		amd64) triple=x86_64-unknown-linux-musl; sha256=$NU_SHA256_AMD64 ;; \
		arm64) triple=aarch64-unknown-linux-musl; sha256=$NU_SHA256_ARM64 ;; \
		*) echo "unsupported architecture: ${TARGETARCH:-$(dpkg --print-architecture)}" >&2; exit 1 ;; \
	esac; \
	name="nu-$NU_VERSION-$triple"; \
	curl -fsSL -o /tmp/nu.tar.gz "https://github.com/nushell/nushell/releases/download/$NU_VERSION/$name.tar.gz"; \
	echo "$sha256  /tmp/nu.tar.gz" | sha256sum -c -; \
	tar -xzf /tmp/nu.tar.gz -C /tmp "$name/nu"; \
	install -m 0755 "/tmp/$name/nu" /usr/local/bin/nu; \
	rm -rf /tmp/nu.tar.gz "/tmp/$name"; \
	nu -c 'version | get version'
ENV SHELL=/usr/local/bin/nu
RUN usermod -s /usr/local/bin/nu root
# System-level so it applies regardless of what's mounted at $HOME.
RUN printf '.claude/\n' > /etc/gitignore \
	&& git config --system core.excludesFile /etc/gitignore
# Let git authenticate to GitHub over HTTPS with gh's stored token (~/.config/gh, persisted by run.nu).
RUN git config --system credential.https://github.com.helper '!gh auth git-credential'

# run.nu mounts the checkout's container/ over this copy; the copy keeps the image usable without the launcher
# Run via sh so exec bits (or a noexec mount) on the checkout do not matter
COPY ./container /opt/claude-wrapper
COPY ./managed-settings.json /etc/claude-code/managed-settings.json
# The service supervisor (container/services.sh) as a command for the Manager
RUN printf '#!/bin/sh\nexec sh /opt/claude-wrapper/services.sh "$@"\n' > /usr/local/bin/claude-services \
	&& chmod 0755 /usr/local/bin/claude-services
ENTRYPOINT ["sh", "/opt/claude-wrapper/entrypoint.sh"]
CMD ["sh", "/opt/claude-wrapper/start.sh"]
