# Claude's Emacs with its Elisp packages, fonts and cursor theme, as one
# environment for the default Nix profile (container/services/emacs/run installs
# it once with `nix profile install --expr 'import ./emacs.nix'`). nixpkgs comes
# from the flake registry, like the `nixpkgs#caddy` the proxy installs, so the
# profile stays on whatever was current at the first install until upgraded.
let
  pkgs = import (builtins.getFlake "nixpkgs") { };
  emacs = pkgs.emacs-pgtk.pkgs.withPackages (epkgs: with epkgs; [
    evil evil-collection which-key vertico orderless marginalia
    magit markdown-mode diff-hl doom-themes treebundel
  ]);
in
pkgs.buildEnv {
  name = "claude-emacs";
  paths = [
    emacs
    # Fonts for fonts.conf (the image has none); the cursor theme for XCURSOR_PATH
    pkgs.jetbrains-mono pkgs.dejavu_fonts pkgs.noto-fonts-color-emoji
    pkgs.rose-pine-cursor
  ];
}
