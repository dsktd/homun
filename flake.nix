{
  description = "Claude Code isolated in a podman container, driven from a host-side Zellij";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      forAllSystems = f: nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ]
        (system: f nixpkgs.legacyPackages.${system});
      # Everything run.nu needs except podman and systemd, which come from the
      # host (they rely on its setuid helpers, config and user session).
      deps = pkgs: with pkgs; [ nushell zellij xdg-dbus-proxy just git ];
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.writeShellApplication {
          name = "claude-wrapper";
          runtimeInputs = deps pkgs;
          text = ''exec nu ${self}/run.nu "$@"'';
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell { packages = deps pkgs; };
      });
    };
}
