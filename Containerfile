FROM docker.io/alpine:3.24
RUN apk --no-cache add curl bash nix git

ENV HOME=/home
RUN mkdir -p /home/.local/bin
RUN curl -fsSL https://claude.ai/install.sh | bash
COPY ./entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/home/.local/bin/claude"]


# RUN nix-channel --add https://nixos.org/channels/nixpkgs-unstable nixpkgs
# RUN nix-channel --update
