# Claude's Emacs: Doom Emacs built by Nix (nix-doom-emacs-unstraightened) from
# Cal's own Doom config, the `doom/` directory of their published dotfiles, with
# the container's local.el and local-packages.el laid over it, plus the fonts,
# cursor theme and tools the `emacs` service needs, as one environment for the
# default Nix profile (container/services/emacs/run installs it once with
# `nix profile install path:/opt/claude-wrapper/emacs`). Everything is pinned by
# flake.lock: `nix flake update` here (then a build) moves Doom, its packages,
# nixpkgs or the dotfiles; `nix flake update dotfiles` just the config.
{
  inputs = {
    unstraightened.url = "github:marienz/nix-doom-emacs-unstraightened/76acb07c80e93ad72499b98077ab1d89d625ff9a";
    nixpkgs.follows = "unstraightened/nixpkgs";
    dotfiles = {
      url = "github:desocketed/dotfiles";
      flake = false;
    };
  };
  outputs = { self, nixpkgs, unstraightened, dotfiles, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; overlays = [ unstraightened.overlays.default ]; };
      # Cal's Doom config as pushed (packages.el, config.el, keybinds.el, notes.el),
      # with the container's gitignored-style local files: config.el ends with
      # (load! "local" nil t) and packages.el with (load! "local-packages" nil t)
      doomDir = pkgs.runCommandLocal "claude-doomdir" { } ''
        cp -r ${dotfiles}/doom $out
        chmod u+w $out
        cp ${./local.el} $out/local.el
        cp ${./local-packages.el} $out/local-packages.el
      '';
      doom = pkgs.doomEmacs {
        inherit doomDir;
        # Doom's own writable directory; its cache, data and state go by XDG_*_HOME
        # (services/emacs/run puts them next to this)
        doomLocalDir = "~/claude/.services/emacs/state/doom";
        emacs = pkgs.emacs-pgtk;
        extraBinPackages = [ pkgs.git pkgs.ripgrep pkgs.fd pkgs.difftastic ];
        # The fork's treebundel-marginalia.el requires marginalia, which its
        # Package-Requires header does not declare
        emacsPackageOverrides = eself: esuper: {
          treebundel = esuper.treebundel.overrideAttrs (old: {
            packageRequires = (old.packageRequires or [ ]) ++ [ eself.marginalia ];
          });
        };
      };
      # bin/claude-emacs talks to the daemon with emacsclient; doomEmacs only ships
      # doom-emacs, doom and doomscript, so take the client of the same Emacs
      emacsclient = pkgs.runCommandLocal "emacsclient" { } ''
        mkdir -p $out/bin
        ln -s ${pkgs.emacs-pgtk}/bin/emacsclient $out/bin/emacsclient
      '';
    in {
      packages.${system}.default = pkgs.buildEnv {
        name = "claude-emacs";
        paths = [
          doom
          emacsclient
          # Fonts for fonts.conf (the image has none); the cursor theme for XCURSOR_PATH
          # (symbols-only: nerd-icons' glyphs for doom-modeline)
          pkgs.jetbrains-mono
          pkgs.dejavu_fonts
          pkgs.noto-fonts-color-emoji
          pkgs.nerd-fonts.symbols-only
          pkgs.rose-pine-cursor
          # difft for difftastic.el (claude-follow's D), rg for consult-ripgrep (SPC s r)
          pkgs.difftastic
          pkgs.ripgrep
          # imv, an image viewer for a Wayland display (container/wayland-run), and
          # mesa's software renderer for its EGL: the container has no GPU
          pkgs.imv
          pkgs.mesa
        ];
      };
    };
}
