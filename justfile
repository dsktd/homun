build:
    podman build . -t claude --pull=always

update: build

refresh:
    podman build . -t claude --pull=always --no-cache

# Symlink this checkout's launcher onto PATH (an existing non-link is kept as <name>.bak)
install name="c" dir=(env("HOME") / ".local/bin"):
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
    "$dir/bin/zellij-mode-hints" --layout > "$tmp/layout.kdl" || { echo "could not render layout" >&2; rm -rf "$tmp"; exit 1; }
    tabs() { sleep 2; zellij -s "$1" action query-tab-names 2>&1 | tr '\n' ' '; }
    cleanup() { for s in diag-plain diag-mine diag-mine-userconf; do zellij kill-session "$s" >/dev/null 2>&1; zellij delete-session "$s" >/dev/null 2>&1; done; }
    cleanup
    trap 'cleanup; rm -rf "$tmp"' EXIT
    echo "zellij: $(zellij --version)  nu: $(nu --version 2>&1)  podman: $(podman --version 2>&1)"
    echo "inside zellij: ${ZELLIJ:-no}  ZELLIJ_* env: $(env | grep '^ZELLIJ' | grep -v '^ZELLIJ=\|^ZELLIJ_SESSION_NAME=\|^ZELLIJ_PANE_ID=' | tr '\n' ' ')"
    zellij attach --create-background diag-plain options --default-layout "$tmp/t.kdl" >/dev/null 2>&1
    echo "1 trivial layout, your config:  tabs: $(tabs diag-plain)  (want LAYOUT-OK)"
    CLAUDE_CONTAINER="{{container}}" zellij --config "$dir/zellij/config.kdl" attach --create-background diag-mine options --default-layout "$tmp/layout.kdl" >/dev/null 2>&1
    echo "2 launcher layout + config:    tabs: $(tabs diag-mine)  (want claude)"
    echo "  panes: $(zellij -s diag-mine action list-panes --command 2>&1 | grep terminal | tr -s ' ' | cut -d' ' -f4- | tr '\n' ';')"
    CLAUDE_CONTAINER="{{container}}" zellij attach --create-background diag-mine-userconf options --default-layout "$tmp/layout.kdl" >/dev/null 2>&1
    echo "3 launcher layout, your config: tabs: $(tabs diag-mine-userconf)  (want claude)"
    echo "4 saved sessions: $(ls -d ~/.cache/zellij/*/session_info/* 2>/dev/null | xargs -r -n1 basename | grep -v '^diag-' | tr '\n' ' ')"
    echo "5 container {{container}}: $(podman ps --filter name='^{{container}}$' --format '{{{{.Status}}' 2>&1)"

# Lint every script and exercise run.nu against fake podman/systemd/git (see tests/run.nu)
test:
    nu tests/run.nu

# --- Snapshots of ~/claude (a bcachefs subvolume). Run these on the host, not in the container.
# One-time setup, with the container stopped (a plain directory cannot be snapshotted):
#   sudo bcachefs subvolume create ~/claude.sv && sudo chown "$USER": ~/claude.sv
#   rsync -a ~/claude/ ~/claude.sv/ && mv ~/claude ~/claude.old && mv ~/claude.sv ~/claude
#   just snap-enable        # tests a snapshot, then makes every container recreate take one first
# Delete ~/claude.old once everything works.

snapdir := env("CLAUDE_SNAPDIR", env("HOME") / "library/backup/dsktd/claude")
claude_dir := env("CLAUDE_DIR", env("HOME") / "claude")

# Read-only snapshot of ~/claude: <UTC time>[-label] under the snapshot dir
snap label="":
    #!/usr/bin/env sh
    set -eu
    mkdir -p "{{snapdir}}"
    id=$(date -u +%Y%m%dT%H%M%SZ)
    [ -z "{{label}}" ] || id="$id-{{label}}"
    sudo bcachefs subvolume snapshot --read-only "{{claude_dir}}" "{{snapdir}}/$id"
    echo "$id"

# Snapshots, newest first
snaps:
    #!/usr/bin/env sh
    ls -1r "{{snapdir}}" 2>/dev/null || echo "no snapshots in {{snapdir}}"

# Copy a snapshot into a new directory (never in place)
snap-restore id dest="":
    #!/usr/bin/env sh
    set -eu
    src="{{snapdir}}/{{id}}"
    dest="{{dest}}"
    [ -n "$dest" ] || dest="$HOME/claude-restore/{{id}}"
    [ -d "$src" ] || { echo "no snapshot $src" >&2; exit 1; }
    [ ! -e "$dest" ] || { echo "$dest exists; pick another destination" >&2; exit 1; }
    mkdir -p "$(dirname "$dest")"
    cp -a --reflink=auto "$src" "$dest"
    echo "restored to $dest"

# Delete one snapshot
snap-delete id:
    sudo bcachefs subvolume delete "{{snapdir}}/{{id}}"

# Keep the newest `keep` snapshots and the newest `keep-pre` taken before a container recreate
snap-prune keep="48" keep-pre="10":
    #!/usr/bin/env sh
    set -eu
    [ -d "{{snapdir}}" ] || exit 0
    ls -1r "{{snapdir}}" | grep -v -e '-pre-recreate$' | tail -n +$(({{keep}} + 1)) | while read -r id; do
        sudo bcachefs subvolume delete "{{snapdir}}/$id" && echo "deleted $id"
    done
    ls -1r "{{snapdir}}" | grep -e '-pre-recreate$' | tail -n +$(({{keep-pre}} + 1)) | while read -r id; do
        sudo bcachefs subvolume delete "{{snapdir}}/$id" && echo "deleted $id"
    done

# Check that snapshots work, then make every container recreate take one first (run.nu looks for this marker)
snap-enable:
    #!/usr/bin/env sh
    set -eu
    id=$(just -f "{{justfile()}}" snap enable-test)
    sudo bcachefs subvolume delete "{{snapdir}}/$id"
    mkdir -p "$HOME/.config/claude"
    : > "$HOME/.config/claude/snapshots"
    echo "snapshots enabled: run.nu snapshots ~/claude (label pre-recreate) before it stops the container"
