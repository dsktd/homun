# The cockpit's Emacs, with the fonts, cursor theme and tools the `emacs` service needs, as
# one environment for a Nix profile of its own (/nix/var/nix/profiles/emacs;
# container/services/emacs/run installs it once). Two packages:
#
#   default  the plain configuration: stock Emacs from nixpkgs with the packages the cockpit's
#            Elisp needs, configured by init.el in the live checkout mount.
#   doom     the Doom flavour: Doom Emacs built by nix-doom-emacs-unstraightened from the
#            host's own Doom directory, the one host config key cockpit.config names, with
#            doom/local.el and doom/local-packages.el laid over it. The directory comes from
#            $HOMUN_COCKPIT_CONFIG, so this one needs `--impure`.
#
# Everything else is pinned by flake.lock: `nix flake update` here (then a build) moves
# nixpkgs, Doom and its packages.
{
  inputs = {
    unstraightened.url = "github:marienz/nix-doom-emacs-unstraightened/76acb07c80e93ad72499b98077ab1d89d625ff9a";
    nixpkgs.follows = "unstraightened/nixpkgs";
  };
  outputs = { self, nixpkgs, unstraightened, ... }:
    let
      forSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
      # What both configurations need next to Emacs itself
      common = pkgs: [
        # Fonts for fonts.conf (the image has none); the cursor theme for XCURSOR_PATH
        # (symbols-only: nerd-icons' glyphs)
        pkgs.jetbrains-mono
        pkgs.dejavu_fonts
        pkgs.noto-fonts
        pkgs.noto-fonts-color-emoji
        pkgs.nerd-fonts.symbols-only
        pkgs.rose-pine-cursor
        # The system clipboard through the forwarded Wayland socket (cockpit.el)
        pkgs.wl-clipboard
        # difft for difftastic.el (claude-follow's D), rg for the transcript's search
        pkgs.difftastic
        pkgs.ripgrep
        # shfmt lays out shell commands opened from claude-transcript (RET)
        pkgs.shfmt
        # imv, an image viewer for a Wayland display (container/wayland-run), and
        # mesa's software renderer for its EGL: the container has no GPU
        pkgs.imv
        pkgs.mesa
        # Tree-sitter grammars as libtree-sitter-<lang>.so in the profile's lib/
        # (cockpit.el adds it to treesit-extra-load-path)
        (pkgs.emacsPackages.treesit-grammars.with-grammars (g: with g; [
          tree-sitter-rust tree-sitter-python tree-sitter-go tree-sitter-c
          tree-sitter-cpp tree-sitter-bash tree-sitter-json tree-sitter-toml
          tree-sitter-yaml tree-sitter-nix tree-sitter-elisp tree-sitter-markdown
          tree-sitter-markdown-inline
        ]))
      ];
      plain = system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in pkgs.buildEnv {
          name = "homun-cockpit";
          paths = [
            # The packages the cockpit's Elisp requires; everything else it uses is built in
            (pkgs.emacs-pgtk.pkgs.withPackages (e: [
              e.magit-section e.consult e.markdown-mode e.org-modern e.timeout e.difftastic e.goggles e.gcmh
            ]))
            pkgs.git
          ] ++ common pkgs;
        };
      doom = system:
        let
          pkgs = import nixpkgs { inherit system; overlays = [ unstraightened.overlays.default ]; };
          config = builtins.getEnv "HOMUN_COCKPIT_CONFIG";
          # The host's Doom directory (packages.el, config.el, ...) with the cockpit's files in
          # its machine-local slots: config.el ends with (load! "local" nil t) and packages.el
          # with (load! "local-packages" nil t)
          doomDir = pkgs.runCommandLocal "homun-cockpit-doomdir" { } ''
            cp -r ${builtins.path { path = config; name = "cockpit-config"; }} $out
            chmod -R u+w $out
            cp ${./doom/local.el} $out/local.el
            cp ${./doom/local-packages.el} $out/local-packages.el
            # No workspaces here: its M-1..M-9 take magit-section's level keys
            # (claude-transcript, the board) and one daemon frame needs no tabs
            sed -i 's/^\(\s*\)workspaces\b/\1;; workspaces/' $out/init.el
            ! grep -q '^[[:space:]]*workspaces\b' $out/init.el
          '';
          # envrc.el runs direnv, which only loads nix-direnv (the cached `use flake`)
          # from a direnvrc: ship one in the profile; services/emacs/run points
          # DIRENV_CONFIG at it, so the user's ~/.config/direnv is left alone
          direnvConfig = pkgs.runCommandLocal "claude-direnv-config" { } ''
            mkdir -p $out/share/claude-direnv
            echo 'source ${pkgs.nix-direnv}/share/nix-direnv/direnvrc' > $out/share/claude-direnv/direnvrc
          '';
          doomEmacs = pkgs.doomEmacs {
            inherit doomDir;
            # Doom's own writable directory; its cache, data and state go by XDG_*_HOME
            # (services/emacs/run puts them next to this)
            doomLocalDir = "~/claude/.services/emacs/state/doom";
            emacs = pkgs.emacs-pgtk;
            # rust-analyzer shells out to cargo and rustc to load a project (no global toolchain here)
            extraBinPackages = [ pkgs.git pkgs.ripgrep pkgs.fd pkgs.difftastic pkgs.shfmt pkgs.rust-analyzer pkgs.cargo pkgs.rustc pkgs.direnv (pkgs.aspellWithDicts (d: [ d.en ])) ];
            emacsPackageOverrides = eself: esuper: {
              # A config.el that uses share-path, a private machine-local package, gets a
              # no-op stand-in (doom/share-path.el) so it does not stop before it loads local.el
              share-path = eself.melpaBuild {
                pname = "share-path";
                version = "0.1";
                src = ./doom/share-path.el;
              };
              # treebundel-marginalia.el requires marginalia, which its Package-Requires
              # header does not declare
              treebundel = esuper.treebundel.overrideAttrs (old: {
                packageRequires = (old.packageRequires or [ ]) ++ [ eself.marginalia ];
              });
            };
          };
          # The service and bin/claude-emacs talk to the daemon with emacsclient; doomEmacs
          # only ships doom-emacs, doom and doomscript, so take the client of the same Emacs
          emacsclient = pkgs.runCommandLocal "emacsclient" { } ''
            mkdir -p $out/bin
            ln -s ${pkgs.emacs-pgtk}/bin/emacsclient $out/bin/emacsclient
          '';
        in
        assert config != "" || throw "the doom package reads $HOMUN_COCKPIT_CONFIG: set it and pass --impure";
        pkgs.buildEnv {
          name = "homun-cockpit-doom";
          paths = [ doomEmacs emacsclient direnvConfig ] ++ common pkgs;
        };
    in {
      packages = forSystems (system: { default = plain system; doom = doom system; });
    };
}
