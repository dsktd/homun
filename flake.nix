{
  description = "Claude Code isolated in a podman container, driven from a host-side Zellij";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      forAllSystems = f: nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ]
        (system: f nixpkgs.legacyPackages.${system});

      claude-ns = pkgs: pkgs.stdenv.mkDerivation {
        pname = "claude-ns";
        version = "0.1.0";
        src = ./ns;
        nativeBuildInputs = [ pkgs.zig.hook ];
        meta.mainProgram = "claude-ns";
      };

      deps = pkgs: with pkgs; [ nushell zellij xdg-dbus-proxy just git (claude-ns pkgs) ];
    in
    {
      packages = forAllSystems (pkgs: {
        claude-ns = claude-ns pkgs;

        # Everything run.nu needs on PATH; run.nu itself runs through this when something is missing
        deps = pkgs.buildEnv { name = "claude-wrapper-deps"; paths = deps pkgs; };

        default = pkgs.writeShellApplication {
          name = "claude-wrapper";
          runtimeInputs = deps pkgs;
          text = ''
            export CLAUDE_WRAPPER_FLAKE=1
            exec nu ${self}/run.nu "$@"
          '';
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell { packages = deps pkgs ++ [ pkgs.zig ]; };
      });
    };
}
