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
    tabs() { sleep 2; zellij -s "$1" action query-tab-names 2>&1 | tr '\n' ' '; }
    cleanup() { for s in diag-plain diag-mine diag-mine-userconf; do zellij kill-session "$s" >/dev/null 2>&1; zellij delete-session "$s" >/dev/null 2>&1; done; }
    cleanup
    trap 'cleanup; rm -rf "$tmp"' EXIT
    echo "zellij: $(zellij --version)  nu: $(nu --version 2>&1)  podman: $(podman --version 2>&1)"
    echo "inside zellij: ${ZELLIJ:-no}  ZELLIJ_* env: $(env | grep '^ZELLIJ' | grep -v '^ZELLIJ=\|^ZELLIJ_SESSION_NAME=\|^ZELLIJ_PANE_ID=' | tr '\n' ' ')"
    zellij attach --create-background diag-plain options --default-layout "$tmp/t.kdl" >/dev/null 2>&1
    echo "1 trivial layout, your config:  tabs: $(tabs diag-plain)  (want LAYOUT-OK)"
    CLAUDE_CONTAINER="{{container}}" zellij --config "$dir/zellij/config.kdl" attach --create-background diag-mine options --default-layout "$dir/zellij/layout.kdl" >/dev/null 2>&1
    echo "2 launcher layout + config:    tabs: $(tabs diag-mine)  (want claude)"
    echo "  panes: $(zellij -s diag-mine action list-panes --command 2>&1 | grep terminal | tr -s ' ' | cut -d' ' -f4- | tr '\n' ';')"
    CLAUDE_CONTAINER="{{container}}" zellij attach --create-background diag-mine-userconf options --default-layout "$dir/zellij/layout.kdl" >/dev/null 2>&1
    echo "3 launcher layout, your config: tabs: $(tabs diag-mine-userconf)  (want claude)"
    echo "4 saved sessions: $(ls -d ~/.cache/zellij/*/session_info/* 2>/dev/null | xargs -r -n1 basename | grep -v '^diag-' | tr '\n' ' ')"
    echo "5 container {{container}}: $(podman ps --filter name='^{{container}}$' --format '{{{{.Status}}' 2>&1)"

# Regenerate the status bar's per-mode key hints in zellij/layout.kdl from zellij/config.kdl
zellij-hints:
    nu bin/zellij-mode-hints
