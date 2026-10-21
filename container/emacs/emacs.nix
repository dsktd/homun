# Claude's Emacs with its Elisp packages, fonts and cursor theme, as one
# environment for the default Nix profile (container/services/emacs/run installs
# it once with `nix profile install --expr 'import ./emacs.nix'`). nixpkgs comes
# from the flake registry, like the `nixpkgs#caddy` the proxy installs, so the
# profile stays on whatever was current at the first install until upgraded.
let
  pkgs = import (builtins.getFlake "nixpkgs") { };
  # The user's treebundel: their fork's `transient' branch, as their Doom
  # packages.el recipe has it (nixpkgs only carries MELPA's), pinned here
  treebundel = epkgs: epkgs.trivialBuild {
    pname = "treebundel";
    version = "0-unstable-a49ba14";
    src = pkgs.fetchFromGitHub {
      owner = "purplg";
      repo = "treebundel";
      rev = "a49ba149c0d5b7bb5b7216dd51f79db01147ddae";
      hash = "sha256-/Pmkyr3IBMxKfz8xh6ZeUbMkWU+2SCD0gL3jBaItM6w=";
    };
    packageRequires = [ epkgs.transient epkgs.marginalia ];
  };
  emacs = pkgs.emacs-pgtk.pkgs.withPackages (epkgs: with epkgs; [
    evil evil-collection which-key vertico orderless marginalia consult
    magit markdown-mode diff-hl goggles evil-goggles doom-themes difftastic (treebundel epkgs)
    doom-modeline nerd-icons hl-todo vi-tilde-fringe
    nix-mode nushell-mode just-mode
  ]);
in
pkgs.buildEnv {
  name = "claude-emacs";
  paths = [
    emacs
    # Fonts for fonts.conf (the image has none); the cursor theme for XCURSOR_PATH
    # (symbols-only: nerd-icons' glyphs for doom-modeline)
    pkgs.jetbrains-mono pkgs.dejavu_fonts pkgs.noto-fonts-color-emoji
    pkgs.nerd-fonts.symbols-only
    pkgs.rose-pine-cursor
    # difft, for difftastic.el (claude-follow's D)
    pkgs.difftastic
    # consult-ripgrep (SPC s r)
    pkgs.ripgrep
    # imv, an image viewer for the host's Wayland display (container/wayland-run)
    pkgs.imv
    # imv needs EGL and the container has no GPU: mesa's software renderer
    pkgs.mesa
  ];
}
