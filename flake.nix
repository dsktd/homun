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

      deps = pkgs: with pkgs; [ nushell zellij chafa wl-clipboard imagemagick xdg-dbus-proxy just git gh (claude-ns pkgs) (homund pkgs) ];

      # The compiled tools of container/, as the Containerfile builds them: Rust as static
      # musl binaries, Go with cgo off, so they run from /usr/local/bin without the store
      digest = pkgs: pkgs.pkgsStatic.rustPlatform.buildRustPackage {
        pname = "claude-digest";
        version = "0.1.0";
        src = ./container/digest;
        cargoLock.lockFile = ./container/digest/Cargo.lock;
      };
      tracker = pkgs: pkgs.pkgsStatic.rustPlatform.buildRustPackage {
        pname = "tracker";
        version = "0.1.0";
        src = ./container/tracker;
        cargoLock.lockFile = ./container/tracker/Cargo.lock;
      };
      homund = pkgs: pkgs.pkgsStatic.rustPlatform.buildRustPackage {
        pname = "homund";
        version = "0.1.0";
        src = ./core/homund;
        cargoLock.lockFile = ./core/homund/Cargo.lock;
        # The integration tests read the repo checkout (tests/golden, container/channels), which
        # the crate-only source lacks; they run as checks.homund-parity on the whole repo.
        cargoTestFlags = [ "--lib" "--bins" ];
      };
      scheduler-channel = pkgs: pkgs.buildGoModule {
        pname = "scheduler-channel";
        version = "0.1.0";
        src = ./container/channels/scheduler-go;
        vendorHash = null;
        env.CGO_ENABLED = 0;
        ldflags = [ "-s" ];
      };
      cockpit-gateway = pkgs: pkgs.buildGoModule {
        pname = "cockpit-gateway";
        version = "0.1.0";
        src = ./container/cockpit-gateway;
        vendorHash = null;
        env.CGO_ENABLED = 0;
        ldflags = [ "-s" ];
      };
      claude-issues = pkgs: pkgs.buildGoModule {
        pname = "claude-issues";
        version = "0.1.0";
        src = ./container/issues;
        vendorHash = null;
        env.CGO_ENABLED = 0;
        ldflags = [ "-s" ];
      };

      # What a container needs before (or without) the Nix profile: the entrypoint's shell
      # and tools, nix itself for the first `nix profile install`, and the compiled tools.
      # At runtime the claude-nix volume covers /nix, so none of this may live there: the
      # whole closure is copied to /opt/store and every /nix/store/ reference rewritten to
      # /opt/store/ (same length, so ELF interpreters, rpaths and compiled-in data paths
      # stay valid). The bare "/nix/store" constant (nix's default store directory) has no
      # trailing slash and is left alone, so nix still uses the volume. This keeps every
      # package the cached dynamic build from nixpkgs; static nix and nushell would be
      # long uncached builds.
      bootstrapEnv = pkgs: pkgs.buildEnv {
        name = "claude-bootstrap";
        paths = with pkgs; [ bashInteractive coreutils util-linuxMinimal gnugrep gnused gawk findutils diffutils which curl gitMinimal cacert tzdata.out nix nushell jq ]
          ++ [ (digest pkgs) (tracker pkgs) (homund pkgs) (scheduler-channel pkgs) (claude-issues pkgs) (cockpit-gateway pkgs) ];
      };
      relocated = path: "/opt/store/${baseNameOf (toString path)}";
      bootstrap = pkgs: pkgs.runCommand "claude-bootstrap-root" {
        closure = pkgs.closureInfo { rootPaths = [ (bootstrapEnv pkgs) ]; };
      } ''
        mkdir -p $out/opt/store
        for p in $(cat $closure/store-paths); do cp -a $p $out/opt/store/; done
        chmod -R u+w $out/opt/store
        grep -rlZF /nix/store/ $out/opt/store | xargs -0 -r sed -i 's|/nix/store/|/opt/store/|g'
        find $out/opt/store -type l | while read -r l; do
          t=$(readlink "$l")
          case $t in /nix/store/*) ln -sfn "/opt/store/''${t#/nix/store/}" "$l" ;; esac
        done
        ln -s ${relocated (bootstrapEnv pkgs)} $out/opt/bootstrap
      '';

      # The rest of the root filesystem the Containerfile sets up
      imageRoot = pkgs: pkgs.runCommand "claude-image-root" { } ''
        mkdir -p $out/bin $out/usr/bin $out/usr/local/bin $out/usr/share $out/etc/nix $out/etc/ssl/certs $out/etc/claude-code \
          $out/opt $out/lib $out/lib64 $out/root $out/tmp $out/var/tmp $out/var/empty $out/nix $out/proc $out/sys $out/dev $out/run $out/home
        ln -s /opt/bootstrap/bin/bash $out/bin/sh
        ln -s /opt/bootstrap/bin/bash $out/bin/bash
        ln -s /opt/bootstrap/bin/false $out/bin/false
        ln -s /opt/bootstrap/bin/env $out/usr/bin/env
        ln -s /opt/bootstrap/bin/nu $out/usr/local/bin/nu
        for t in claude-digest tracker homund scheduler-channel claude-issues cockpit-gateway; do ln -s /opt/bootstrap/bin/$t $out/usr/local/bin/$t; done
        ln -s /opt/bootstrap/share/zoneinfo $out/usr/share/zoneinfo
        ln -s /opt/bootstrap/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/ca-certificates.crt
        # Claude Code's own binary (curl | bash in entrypoint.sh) is linked against glibc at the usual place
        ld=$(basename ${pkgs.stdenv.cc.bintools.dynamicLinker})
        ln -s ${relocated pkgs.glibc}/lib/$ld $out/lib64/$ld
        ln -s ${relocated pkgs.glibc}/lib/$ld $out/lib/$ld
        # root with nu as login shell; the nixbld users nix builds as (Containerfile)
        {
          echo 'root:x:0:0:root:/root:/usr/local/bin/nu'
          echo 'nobody:x:65534:65534:nobody:/var/empty:/bin/false'
          for i in 1 2 3 4 5 6 7 8; do echo "nixbld$i:x:$((30000 + i)):30000:Nix build user $i:/var/empty:/bin/false"; done
        } > $out/etc/passwd
        printf '%s\n' 'root:x:0:' 'nogroup:x:65534:' 'nixbld:x:30000:nixbld1,nixbld2,nixbld3,nixbld4,nixbld5,nixbld6,nixbld7,nixbld8' > $out/etc/group
        printf '%s\n' /bin/sh /bin/bash /usr/local/bin/nu > $out/etc/shells
        printf '%s\n' 'passwd: files' 'group: files' 'hosts: files dns' > $out/etc/nsswitch.conf
        printf '%s\n' 'build-users-group = nixbld' 'experimental-features = nix-command flakes' 'sandbox = false' > $out/etc/nix/nix.conf
        printf '.claude/\n' > $out/etc/gitignore
        printf '%s\n' '[core]' '	excludesFile = /etc/gitignore' '[credential "https://github.com"]' '	helper = !gh auth git-credential' > $out/etc/gitconfig
        cp ${./managed-settings.json} $out/etc/claude-code/managed-settings.json
        cp -r ${./container} $out/opt/homun
        ln -s homun $out/opt/claude-wrapper
        # The shims of the Containerfile, verbatim
        cd $out/usr/local/bin
        printf '#!/bin/sh\nexec sh /opt/homun/services.sh "$@"\n' > claude-services
        printf '#!/bin/sh\ncommand -v python3 >/dev/null || { echo "claude-busy: no python3" >&2; exit 0; }\nexec python3 /opt/homun/claude-busy "$@"\n' > claude-busy
        printf '#!/bin/sh\nexec sh /opt/homun/homun-msg "$@"\n' > homun-msg
        printf '#!/bin/sh\nexec python3 /opt/homun/claude-question "$@"\n' > claude-question
        printf '#!/bin/sh\nexec python3 /opt/homun/claude-view "$@"\n' > claude-view
        printf '#!/bin/sh\nexec sh /opt/homun/claude-shot "$@"\n' > claude-shot
        printf '#!/bin/sh\nexec sh /opt/homun/wayland-run "$@"\n' > wayland-run
        chmod 0755 homun-msg claude-services claude-busy claude-question claude-view claude-shot wayland-run
      '';

      # The image: experimental, step 1 of docs/nix-base-image.md. `nix run .#image | podman load`
      # (just build-nix). Nothing under /nix: the volume is the store (includeStorePaths = false).
      image = pkgs: pkgs.dockerTools.streamLayeredImage {
        name = "claude-nix";
        tag = "latest";
        includeStorePaths = false;
        extraCommands = ''
          cp -r ${bootstrap pkgs}/. .
          chmod -R u+w .
          cp -r ${imageRoot pkgs}/. .
          chmod -R u+w .
        '';
        fakeRootCommands = "chmod 1777 tmp var/tmp";
        config = {
          Entrypoint = [ "sh" "/opt/homun/entrypoint.sh" ];
          Cmd = [ "sh" "/opt/homun/start.sh" ];
          Env = [
            "PATH=/opt/homun/shims:/nix/var/nix/profiles/default/bin:/usr/local/bin:/opt/bootstrap/bin:/usr/bin:/bin"
            "SHELL=/usr/local/bin/nu"
            "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
            "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
          ];
        };
      };
    in
    {
      checks = forAllSystems (pkgs: {
        homund-parity = (homund pkgs).overrideAttrs (old: {
          pname = "homund-parity";
          src = self;
          sourceRoot = "source/core/homund";
          cargoTestFlags = [ ];
          nativeCheckInputs = [ pkgs.python3 pkgs.nushell pkgs.git ];
        });
      });

      packages = forAllSystems (pkgs: {
        claude-ns = claude-ns pkgs;
        digest = digest pkgs;
        tracker = tracker pkgs;
        homund = homund pkgs;
        scheduler-channel = scheduler-channel pkgs;
        claude-issues = claude-issues pkgs;
        cockpit-gateway = cockpit-gateway pkgs;
        image = image pkgs;

        # Everything run.nu needs on PATH; run.nu itself runs through this when something is missing
        deps = pkgs.buildEnv { name = "homun-deps"; paths = deps pkgs; };

        default = pkgs.writeShellApplication {
          name = "homun";
          runtimeInputs = deps pkgs;
          text = ''
            export HOMUN_FLAKE=1
            exec nu ${self}/run.nu "$@"
          '';
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell { packages = deps pkgs ++ [ pkgs.zig ]; };
      });
    };
}
