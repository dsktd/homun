FROM docker.io/debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
	curl bash nix-bin git ca-certificates \
	&& rm -rf /var/lib/apt/lists/*

ENV HOME=/home
RUN mkdir -p /home/.local/bin
RUN curl -fsSL https://claude.ai/install.sh | bash
COPY ./entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/home/.local/bin/claude"]


# RUN nix-channel --add https://nixos.org/channels/nixpkgs-unstable nixpkgs
# RUN nix-channel --update
