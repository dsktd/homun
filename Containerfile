# claude-digest (container/digest): static musl build, no toolchain at runtime
FROM docker.io/rust:1 AS digest
RUN rustup target add "$(uname -m)-unknown-linux-musl"
COPY ./container/digest /src
WORKDIR /src
RUN cargo build --release --target "$(uname -m)-unknown-linux-musl" \
	&& install -D "target/$(uname -m)-unknown-linux-musl/release/claude-digest" /out/claude-digest

# tracker (container/tracker): the org-mode issue tracker CLI, the same way
FROM docker.io/rust:1 AS tracker
RUN rustup target add "$(uname -m)-unknown-linux-musl"
COPY ./container/tracker /src
WORKDIR /src
RUN cargo build --release --target "$(uname -m)-unknown-linux-musl" \
	&& install -D "target/$(uname -m)-unknown-linux-musl/release/tracker" /out/tracker

FROM docker.io/golang:1-bookworm AS channel
WORKDIR /src
COPY container/channels/scheduler-go/ .
RUN CGO_ENABLED=0 go build -trimpath -ldflags=-s -o /scheduler-channel .

# homund (core/homund): the bus door `homund msg` behind homun-msg, the same way
FROM docker.io/rust:1 AS homund
RUN rustup target add "$(uname -m)-unknown-linux-musl"
COPY ./core/homund /src
WORKDIR /src
RUN cargo build --release --target "$(uname -m)-unknown-linux-musl" \
	&& install -D "target/$(uname -m)-unknown-linux-musl/release/homund" /out/homund

# claude-issues (container/issues): the read-only web view of the tracker, a static Go binary
FROM docker.io/golang:1-bookworm AS issues
WORKDIR /src
COPY container/issues/ .
RUN CGO_ENABLED=0 go build -trimpath -ldflags=-s -o /out/claude-issues .

# cockpit-gateway (container/cockpit-gateway): the remote cockpit's stream and actions, a static Go binary
FROM docker.io/golang:1-bookworm AS gateway
WORKDIR /src
COPY container/cockpit-gateway/ .
RUN CGO_ENABLED=0 go build -trimpath -ldflags=-s -o /out/cockpit-gateway .

FROM docker.io/debian:trixie-slim
# Debian's git, gh, jq, libnotify, runit (and the nu tarball below) are bootstrap and
# fallback only: entrypoint.sh installs Nix builds of them (container/tools) into the
# default profile, which PATH prefers; `nix profile upgrade --profile
# /nix/var/nix/profiles/default tools` moves that install.
RUN apt-get update && apt-get install -y --no-install-recommends \
	curl bash nix-bin git ca-certificates libnotify-bin jq gh runit \
	&& rm -rf /var/lib/apt/lists/*
# Nix runs as root here, builds as the nixbld users (Debian's nix.conf names the group
# but never creates it). No sandbox: the rootless container's root lacks CAP_SYS_ADMIN
# for the build namespaces (Nix fails with "cannot set host name"), so without build
# users a builder that writes to $HOME (cargo's `mkdir -p $HOME/.cargo` in a check
# phase did) creates /homeless-shelter, after which Nix refuses every build until it
# is removed. An unprivileged builder cannot create it (uids 30001+ are inside the
# 65536 ids a rootless container maps).
# Flakes replace channels: `nix shell nixpkgs#foo` resolves nixpkgs-unstable via the registry.
RUN groupadd -g 30000 nixbld \
	&& for i in 1 2 3 4 5 6 7 8; do useradd -u $((30000 + i)) -g nixbld -G nixbld -M -N -r \
		-s /usr/sbin/nologin -c "Nix build user $i" nixbld$i; done \
	&& mkdir -p /etc/nix && printf '%s\n' \
	'build-users-group = nixbld' \
	'experimental-features = nix-command flakes' \
	'sandbox = false' \
	>> /etc/nix/nix.conf
ENV PATH=/opt/homun/shims:/nix/var/nix/profiles/default/bin:$PATH:/nix/var/nix/profiles/emacs/bin
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
COPY ./container /opt/homun
# The old name stays as a link: hooks in running containers and ~/.claude/settings.json still reference it
RUN ln -s homun /opt/claude-wrapper
COPY --from=digest /out/claude-digest /usr/local/bin/claude-digest
COPY --from=tracker /out/tracker /usr/local/bin/tracker
COPY --from=homund /out/homund /usr/local/bin/homund
COPY --from=issues /out/claude-issues /usr/local/bin/claude-issues
COPY --from=gateway /out/cockpit-gateway /usr/local/bin/cockpit-gateway
COPY ./managed-settings.json /etc/claude-code/managed-settings.json
# The service supervisor (container/services.sh; runit runs the services) as a command for the Manager
RUN printf '#!/bin/sh\nexec sh /opt/homun/services.sh "$@"\n' > /usr/local/bin/claude-services \
	&& chmod 0755 /usr/local/bin/claude-services
# What an update would kill (container/claude-busy; python3 comes from the Nix profile)
RUN printf '#!/bin/sh\ncommand -v python3 >/dev/null || { echo "claude-busy: no python3" >&2; exit 0; }\nexec python3 /opt/homun/claude-busy "$@"\n' > /usr/local/bin/claude-busy \
	&& chmod 0755 /usr/local/bin/claude-busy
# The bus (container/homun-msg)
RUN printf '#!/bin/sh\nexec sh /opt/homun/homun-msg "$@"\n' > /usr/local/bin/homun-msg \
	&& chmod 0755 /usr/local/bin/homun-msg
# Tell the user through the attention ladder (container/homun-push)
RUN printf '#!/bin/sh\nexec sh /opt/homun/homun-push "$@"\n' > /usr/local/bin/homun-push \
	&& chmod 0755 /usr/local/bin/homun-push
# Questions for the user (container/claude-question)
RUN printf '#!/bin/sh\nexec python3 /opt/homun/claude-question "$@"\n' > /usr/local/bin/claude-question \
	&& chmod 0755 /usr/local/bin/claude-question
# Images for the user (container/claude-view; the host draws them)
RUN printf '#!/bin/sh\nexec python3 /opt/homun/claude-view "$@"\n' > /usr/local/bin/claude-view \
	&& chmod 0755 /usr/local/bin/claude-view
# CAD scripting (container/microcad: nixpkgs binary, shown by the cad service)
RUN ln -s /opt/homun/microcad /usr/local/bin/microcad
# Long-running jobs the status page and the cockpit board show (container/claude-job)
RUN printf '#!/bin/sh\nexec python3 -I /opt/homun/claude-job "$@"\n' > /usr/local/bin/claude-job \
	&& chmod 0755 /usr/local/bin/claude-job
# The private display's tools (container/claude-shot, container/wayland-run)
# emacsclient: logs --eval calls to the Emacs socket (container/homun-eval). The copy that wins is
# /opt/homun/shims/emacsclient, first on PATH; this one is the fallback behind the Nix profile.
RUN printf '#!/bin/sh\nexec sh /opt/homun/emacsclient-shim "$@"\n' > /usr/local/bin/emacsclient \
	&& chmod 0755 /usr/local/bin/emacsclient
RUN printf '#!/bin/sh\nexec sh /opt/homun/claude-shot "$@"\n' > /usr/local/bin/claude-shot \
	&& printf '#!/bin/sh\nexec sh /opt/homun/wayland-run "$@"\n' > /usr/local/bin/wayland-run \
	&& chmod 0755 /usr/local/bin/claude-shot /usr/local/bin/wayland-run
COPY --from=channel /scheduler-channel /usr/local/bin/scheduler-channel
ENTRYPOINT ["sh", "/opt/homun/entrypoint.sh"]
CMD ["sh", "/opt/homun/start.sh"]
