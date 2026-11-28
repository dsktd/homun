build:
    podman build . -t claude --pull=always

# The update on a host without home-manager (there a switch does this): pull, then build the image
# for the new code and roll the containers onto it behind the health gates (bin/claude-update)
update:
    git -C "{{justfile_directory()}}" pull --ff-only
    nu "{{justfile_directory()}}/bin/claude-update" sync

refresh:
    podman build . -t claude --pull=always --no-cache

# The Nix-built image (flake output `image`, experimental: docs/nix-base-image.md step 1); the stream names it claude-nix:latest
build-nix:
    nix run .#image | podman load

# Symlink this checkout's launcher onto PATH (an existing non-link is kept as <name>.bak)
install name="homun" dir=(env("HOME") / ".local/bin"):
    #!/usr/bin/env sh
    set -eu
    target="{{dir}}/{{name}}"
    mkdir -p "{{dir}}"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
        mv "$target" "$target.bak"
        echo "Moved existing $target to $target.bak"
    fi
    ln -sfn "{{justfile_directory()}}/run.nu" "$target"
    echo "$target -> {{justfile_directory()}}/run.nu"

# Check how this machine's Zellij handles the launcher's layout; paste the output back
diagnose container="claude-manager":
    #!/usr/bin/env sh
    dir="{{justfile_directory()}}"
    tmp=$(mktemp -d)
    printf 'layout { tab name="LAYOUT-OK" { pane command="sleep" { args "300"; }; }; }\n' > "$tmp/t.kdl"
    cp "$dir/zellij/layout.kdl" "$tmp/layout.kdl"
    tabs() { sleep 2; zellij -s "$1" action query-tab-names 2>&1 | tr '\n' ' '; }
    cleanup() { for s in diag-plain diag-mine diag-mine-userconf; do zellij kill-session "$s" >/dev/null 2>&1; zellij delete-session "$s" >/dev/null 2>&1; done; }
    cleanup
    trap 'cleanup; rm -rf "$tmp"' EXIT
    echo "zellij: $(zellij --version)  nu: $(nu --version 2>&1)  podman: $(podman --version 2>&1)"
    echo "inside zellij: ${ZELLIJ:-no}  ZELLIJ_* env: $(env | grep '^ZELLIJ' | grep -v '^ZELLIJ=\|^ZELLIJ_SESSION_NAME=\|^ZELLIJ_PANE_ID=' | tr '\n' ' ')"
    zellij attach --create-background diag-plain options --default-layout "$tmp/t.kdl" >/dev/null 2>&1
    echo "1 trivial layout, your config:  tabs: $(tabs diag-plain)  (want LAYOUT-OK)"
    CLAUDE_CONTAINER="{{container}}" zellij --config "$dir/zellij/config.kdl" attach --create-background diag-mine options --default-layout "$tmp/layout.kdl" >/dev/null 2>&1
    echo "2 launcher layout + config:    tabs: $(tabs diag-mine)  (want manager)"
    echo "  panes: $(zellij -s diag-mine action list-panes --command 2>&1 | grep terminal | tr -s ' ' | cut -d' ' -f4- | tr '\n' ';')"
    CLAUDE_CONTAINER="{{container}}" zellij attach --create-background diag-mine-userconf options --default-layout "$tmp/layout.kdl" >/dev/null 2>&1
    echo "3 launcher layout, your config: tabs: $(tabs diag-mine-userconf)  (want manager)"
    echo "4 saved sessions: $(ls -d ~/.cache/zellij/*/session_info/* 2>/dev/null | xargs -r -n1 basename | grep -v '^diag-' | tr '\n' ' ')"
    echo "5 container {{container}}: $(podman ps --filter name='^{{container}}$' --format '{{{{.Status}}' 2>&1)"

# Lint every script and exercise run.nu against fake podman/systemd/git (see tests/run.nu)
test:
    nu tests/run.nu

# --- Encrypted p2p port forwarding with dumbpipe (Iroh: QUIC, hole-punching, relay fallback,
# no accounts). Works from the host or inside the container; the ticket it prints is the secret.
# Offer 127.0.0.1:<port> here; prints the ticket for `just reach`
expose port:
    nix shell nixpkgs#dumbpipe -c dumbpipe listen-tcp --host 127.0.0.1:{{port}}

# Mirror a remote `just expose` on 127.0.0.1:<port> here
reach ticket port:
    nix shell nixpkgs#dumbpipe -c dumbpipe connect-tcp --addr 127.0.0.1:{{port}} {{ticket}}

# --- Snapshots of ~/claude/.bare and ~/claude/.services (each its own bcachefs subvolume), never of
# the whole of ~/claude, so build churn is not pinned. ~/claude/.build is a third subvolume that is
# not snapshotted. Run these on the host, not in the container.
# One-time setup, with the container stopped (a plain directory cannot be snapshotted):
#   just snap-migrate       # makes .bare, .services and .build subvolumes; keeps the .old dirs
#   just snap-enable        # tests a snapshot, then makes every container recreate take one first
# Snapshots run `sudo -n` (never a password prompt, which would hang a recreate), so sudoers needs:
#   <user> ALL=(root) NOPASSWD: /usr/bin/bcachefs subvolume snapshot *, /usr/bin/bcachefs subvolume delete *, /usr/bin/bcachefs subvolume create *
# (`create` is only for snap-migrate and can be removed again afterwards.)
# Layout: <snapdir>/bare/<id>, <snapdir>/services/<id>. Whole-~/claude snapshots from before the
# split sit directly in <snapdir>/ ("legacy"): listed, restorable, and removed only by
# `just snap-delete <id>` or `just snap-prune-legacy`, which you run yourself (snap-prune never does).
# Automatic: a systemd user timer, see "Snapshot timer" in docs/development.md.

snapdir := env("CLAUDE_SNAPDIR", env("HOME") / "library/backup/dsktd/claude")
claude_dir := env("CLAUDE_DIR", env("HOME") / "claude")
snap_subs := "bare services"

# Shell snippet: reject an $id that is not <UTC time>[-label] (no slashes, quotes or dots)
check_id := '''
case $id in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z | [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-*) ;; *) echo "not a snapshot id: $id" >&2; exit 1 ;; esac
    case $id in *[!A-Za-z0-9-]*) echo "not a snapshot id: $id" >&2; exit 1 ;; esac
    '''

# Read-only snapshots of .bare and .services: <UTC time>[-label] under <snapdir>/bare and /services
snap $label="":
    #!/usr/bin/env sh
    set -eu
    case $label in *[!A-Za-z0-9-]*) echo "label must match [A-Za-z0-9-]+" >&2; exit 1 ;; esac
    id=$(date -u +%Y%m%dT%H%M%SZ)
    [ -z "$label" ] || id="$id-$label"
    for sub in {{snap_subs}}; do
        mkdir -p "{{snapdir}}/$sub"
        sudo -n bcachefs subvolume snapshot --read-only "{{claude_dir}}/.$sub" "{{snapdir}}/$sub/$id"
    done
    echo "$id"

# Snapshot ids, newest first; whole-~/claude ones from before the split are marked (legacy)
snaps:
    #!/usr/bin/env sh
    {
        for sub in {{snap_subs}}; do ls -1 "{{snapdir}}/$sub" 2>/dev/null; done | sort -u
        ls -1 "{{snapdir}}" 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z' | sed 's/$/ (legacy)/'
    } | sort -r | { grep . || echo "no snapshots in {{snapdir}}"; }

# Copy a snapshot into a new directory (never in place): <dest>/bare and <dest>/services, or a whole legacy tree
snap-restore $id $dest="":
    #!/usr/bin/env sh
    set -eu
    {{check_id}}
    [ -n "$dest" ] || dest="$HOME/claude-restore/$id"
    [ ! -e "$dest" ] || { echo "$dest exists; pick another destination" >&2; exit 1; }
    mkdir -p "$dest"
    found=
    for sub in {{snap_subs}}; do
        [ -d "{{snapdir}}/$sub/$id" ] || continue
        cp -a --reflink=auto "{{snapdir}}/$sub/$id" "$dest/$sub"
        found=1
    done
    if [ -z "$found" ] && [ -d "{{snapdir}}/$id" ]; then
        rmdir "$dest"
        cp -a --reflink=auto "{{snapdir}}/$id" "$dest"
        found=1
    fi
    [ -n "$found" ] || { rmdir "$dest"; echo "no snapshot $id" >&2; exit 1; }
    echo "restored to $dest"

# Delete one snapshot (both subvolumes' copies; or the legacy whole-~/claude one)
snap-delete $id:
    #!/usr/bin/env sh
    set -eu
    {{check_id}}
    for p in {{snapdir}}/bare/$id {{snapdir}}/services/$id {{snapdir}}/$id; do
        [ -d "$p" ] && sudo bcachefs subvolume delete "$p"
    done
    exit 0

# Keep the newest `keep` unlabelled snapshots and the newest `keep-pre` taken before a container
# recreate; other labels (just snap before-migration) and legacy whole-~/claude snapshots are never pruned.
# Prune old snapshots of .bare and .services (safe for a timer)
snap-prune keep="48" keep-pre="10":
    #!/usr/bin/env sh
    set -eu
    for sub in {{snap_subs}}; do
        d="{{snapdir}}/$sub"
        [ -d "$d" ] || continue
        ls -1r "$d" | grep -E '^[0-9]{8}T[0-9]{6}Z$' | tail -n +$(({{keep}} + 1)) | while read -r id; do
            sudo -n bcachefs subvolume delete "$d/$id" && echo "deleted $sub/$id"
        done
        ls -1r "$d" | grep -e '-pre-recreate$' | tail -n +$(({{keep-pre}} + 1)) | while read -r id; do
            sudo -n bcachefs subvolume delete "$d/$id" && echo "deleted $sub/$id"
        done
    done

# Delete legacy whole-~/claude snapshots (top level of the snapdir), keeping the newest `keep` (default 0: all); run by hand
snap-prune-legacy keep="0":
    #!/usr/bin/env sh
    set -eu
    ls -1r "{{snapdir}}" 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z' | tail -n +$(({{keep}} + 1)) | while read -r id; do
        sudo bcachefs subvolume delete "{{snapdir}}/$id" && echo "deleted legacy $id"
    done

# (create, cp -a --reflink, swap; keeps the .old directories and prints the rm line)
# One-time, host, container stopped: turn .bare, .services and .build into bcachefs subvolumes
snap-migrate:
    #!/usr/bin/env sh
    set -eu
    if podman ps --format '{{{{.Names}}' 2>/dev/null | grep -qx 'claude-.*'; then
        echo "a claude container is running: stop it first (homun container stop)" >&2; exit 1
    fi
    cd "{{claude_dir}}"
    olds=
    for n in .bare .services .build; do
        if [ -d "$n.old" ]; then echo "$n.old exists: remove or rename it first" >&2; exit 1; fi
    done
    for n in .bare .services .build; do
        sudo bcachefs subvolume create "$n.sv"
        sudo chown "$(id -u):$(id -g)" "$n.sv"
        [ ! -d "$n" ] || cp -a --reflink=auto "$n/." "$n.sv/"
        [ ! -d "$n" ] || mv "$n" "$n.old"
        mv "$n.sv" "$n"
        [ ! -d "$n.old" ] || olds="$olds {{claude_dir}}/$n.old"
        echo "$n is now a subvolume"
    done
    [ -z "$olds" ] || echo "check everything works, then: rm -rf$olds"

# Check that snapshots work, then make every container recreate take one first (run.nu looks for this marker)
snap-enable:
    #!/usr/bin/env sh
    set -eu
    id=$(just -f "{{justfile()}}" snap enable-test)
    for sub in {{snap_subs}}; do sudo -n bcachefs subvolume delete "{{snapdir}}/$sub/$id"; done
    mkdir -p "$HOME/.config/claude"
    : > "$HOME/.config/claude/snapshots"
    echo "snapshots enabled: .bare and .services are snapshotted (label pre-recreate) before each container recreate"
