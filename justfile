build:
    podman build . -t claude --pull=always

update:
    podman build . -t claude --pull=always --build-arg="CACHEBUST=$(date +%s)"

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
