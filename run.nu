#!/usr/bin/env nu
# Launcher for the Manager container. Host-only subcommands refuse to run where
# /run/.containerenv exists; CLAUDE_WRAPPER_CONTAINERENV points them at another
# marker file (the test suite uses it to run inside the container).

use std/log

const SELF: string = path self | path expand
const SCRIPT_DIR: string = $SELF | path dirname
const LIB = $SCRIPT_DIR | path join lib

use ($LIB | path join clone.nu)
use ($LIB | path join hints.nu)
use ($LIB | path join keywords.nu)
use ($LIB | path join mounts.nu)
use ($LIB | path join ports.nu)

# Host tools the launcher needs besides nushell itself; the flake provides them all
const TOOLS = [zellij xdg-dbus-proxy just git claude-ns]

# Subcommands that run without any of TOOLS (only podman, nu and the host's own programs)
const NO_TOOLS = [emacs usage]

# This script's arguments as typed: nushell gives top-level code no argv, and a
# re-exec must pass them on unchanged, so read them back from the kernel
def script-args []: nothing -> list<string> {
    # NUL-terminated, so the split ends with one empty element; keep real empty args
    let argv = open --raw /proc/self/cmdline | split row (char nul) | drop 1
    let at = $argv | enumerate | where {|e| ($e.item | path expand) == $SELF } | get index.0?
    if $at == null { return [] }
    $argv | skip ($at + 1)
}

# A bare ./run.nu (or the `c` symlink) seldom has every tool on PATH: fetch them
# from the flake's `deps` package and re-run this same file (not the store copy,
# so live mounts like container/ keep pointing at the checkout), once: the exec
# sets CLAUDE_WRAPPER_FLAKE, as the `nix run` wrapper does. `path:` so an
# uncommitted checkout works. Costs nothing when all are present, and is skipped
# in a container, where the host-only guard gives the better error. The
# subcommands in NO_TOOLS need none of them, so a minimal PATH (a window
# manager keybind) skips the slow flake for those.
def bootstrap [] {
    if ($env.CLAUDE_WRAPPER_FLAKE? | default "") != "" { return }
    if (($env.CLAUDE_WRAPPER_CONTAINERENV? | default /run/.containerenv) | path exists) { return }
    if (script-args | first | default "") in $NO_TOOLS { return }
    let missing = $TOOLS | where {|t| which $t | is-empty }
    if ($missing | is-empty) { return }
    if (which nix | is-empty) {
        log error $"Missing from PATH: ($missing | str join ', '), and no `nix` to fetch them with; install nix or those tools \(see ($SCRIPT_DIR)/flake.nix)"
        exit 1
    }
    log info $"Missing from PATH: ($missing | str join ', '); starting through the flake"
    with-env {CLAUDE_WRAPPER_FLAKE: "1"} {
        exec nix shell $"path:($SCRIPT_DIR)#deps" -c nu $SELF ...(script-args)
    }
}

bootstrap

const NAME = "claude-manager"
const IMAGE = "claude"
const SCRATCH = "/tmp/claude-0"

def root []: nothing -> path { $env.HOME | path join claude }

def state []: nothing -> path { $env.HOME | path join .local share claude }

def config []: nothing -> path { $env.HOME | path join .config claude }

def mounts-file []: nothing -> path { config | path join mounts.nuon }

def ports-file []: nothing -> path { config | path join ports.nuon }

# Per-user scratch for files that only matter while the session is up
def runtime-dir []: nothing -> path {
    let xdg = $env.XDG_RUNTIME_DIR? | default ""
    if not ($xdg | is-empty) { return $xdg }
    let dir = $"/tmp/claude-wrapper-(id -u)"
    mkdir $dir
    $dir
}

def host-only [] {
    let marker = $env.CLAUDE_WRAPPER_CONTAINERENV? | default /run/.containerenv
    if ($marker | path exists) {
        log error 'This command only runs on the host, not inside a container'
        exit 1
    }
}

def ensure-notify-proxy []: nothing -> any {
    const UNIT = "claude-dbus-proxy"

    let runtime_dir = $env.XDG_RUNTIME_DIR?
    let bus = $env.DBUS_SESSION_BUS_ADDRESS?
    if $runtime_dir == null or $bus == null or (which xdg-dbus-proxy | is-empty) {
        log warning 'xdg-dbus-proxy or session bus unavailable, desktop notifications disabled'
        return null
    }

    let socket = $runtime_dir | path join claude-bus

    let active = (do { systemctl --user is-active --quiet $UNIT } | complete).exit_code == 0
    if not $active {
        log debug $'Starting ($UNIT)'
        rm -f $socket
        systemd-run --user --quiet --collect $'--unit=($UNIT)' xdg-dbus-proxy $bus $socket --filter --talk=org.freedesktop.Notifications
        for _ in 1..50 {
            if ($socket | path exists) { break }
            sleep 100ms
        }
    }

    if ($socket | path exists) { $socket } else {
        log warning $'($UNIT) failed to create ($socket), desktop notifications disabled'
        null
    }
}

# The host's Wayland socket, for the frames of the `emacs` service (mounted as a
# file like the notify socket; the service's env points WAYLAND_DISPLAY at it)
def wayland-socket []: nothing -> any {
    let display = $env.WAYLAND_DISPLAY? | default ""
    let socket = if ($display | str starts-with "/") { $display } else { ($env.XDG_RUNTIME_DIR? | default "") | path join $display }
    if $display != "" and ($socket | str starts-with "/") and ($socket | path exists) { return $socket }
    log warning 'No Wayland socket (WAYLAND_DISPLAY/XDG_RUNTIME_DIR); the emacs service will have no display'
    null
}

# The host's timezone name (America/New_York), from where /etc/localtime resolves to, or null. The file
# mount alone is not enough: the container's /etc/localtime is a symlink to Etc/UTC, so it replaces that
# zone's data, and programs that go by the zone's name (Node, so the scheduler sidecar's crons) stay in UTC.
def host_timezone []: nothing -> any {
    if not ('/etc/localtime' | path exists) { return null }
    let parts = ('/etc/localtime' | path expand | path split)
    let at = ($parts | enumerate | where item == zoneinfo | get -o 0.index)
    if $at == null or ($at + 1) >= ($parts | length) { null } else { $parts | skip ($at + 1) | str join '/' }
}

def plan [notify_socket: any, wayland_socket: any]: nothing -> record {
    let state = state

    # Claude's state, persisted on the host; `kind` is what prepare creates so podman does not guess
    let state_mounts = [
        {src: ($state | path join claude), dst: ($env.HOME | path join .claude), kind: dir}
        {src: ($state | path join claude.json), dst: ($env.HOME | path join .claude.json), kind: file}
        {src: ($state | path join gh), dst: ($env.HOME | path join .config gh), kind: dir}
        # A directory, not a file: git writes config via .lock + rename, which fails (EBUSY) on a file bind mount.
        # prep touches config inside it, since --global only uses this file instead of ~/.gitconfig when it exists.
        {src: ($state | path join git), dst: ($env.HOME | path join .config git), kind: dir}
        {src: ($state | path join scratch), dst: $SCRATCH, kind: dir}
    ]

    let mounts = [
        {src: (root), dst: (root), mode: rw}
        ...($state_mounts | each {|m| {src: $m.src, dst: $m.dst, mode: rw} })

        # Over the image's copy, so edits to the checkout's scripts apply without a rebuild. Only when the
        # source is really there: a missing directory would be mounted as an empty one, hiding the image's copy.
        ...(if ($SCRIPT_DIR | path join container entrypoint.sh | path exists) {
            [{src: ($SCRIPT_DIR | path join container), dst: /opt/claude-wrapper, mode: ro}]
        } else { [] })

        # The host's timezone, so dates inside (and in the status line's usage samples) read in local time.
        # Resolved first: on NixOS it is a symlink into the store, and the container has no store at that path.
        ...(if ('/etc/localtime' | path exists) { [{src: ('/etc/localtime' | path expand), dst: /etc/localtime, mode: ro}] } else { [] })

        ...(if $notify_socket == null { [] } else { [{src: $notify_socket, dst: /run/claude-bus, mode: rw}] })
        ...(if $wayland_socket == null { [] } else { [{src: $wayland_socket, dst: /run/claude-wayland, mode: rw}] })
    ]

    let args = [
        --name=($NAME)
        --hostname=($NAME)
        --workdir=(root)

        --env $'PS1=(ansi magenta_bold)\h(ansi reset)$ '
        --env ENABLE_LSP_TOOL=1
        --env COLORTERM=truecolor
        --env HOME=($env.HOME)
        ...(host_timezone | if $in == null { [] } else { [--env $'TZ=($in)'] })
        ...(if $notify_socket == null { [] } else { [--env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/claude-bus] })

        ...($mounts | each {|m| $'--volume=($m.src):($m.dst):($m.mode)' })
        --volume=claude-nix:/nix
        $'--volume=claude-nix-cache:($env.HOME)/.cache/nix'
        $'--volume=claude-code:($env.HOME)/.local/share/claude'
        $'--volume=claude-code-bin:($env.HOME)/.local/bin'

        --security-opt=unmask=/proc/*
    ]

    let prep = {
        mkdirs: [(root) (root | path join .bare) (root | path join .services) ...($state_mounts | where kind == dir | get src)]
        touches: [...($state_mounts | where kind == file | get src) ($state | path join git config)]
        seed: {src: ($SCRIPT_DIR | path join manager CLAUDE.md), dst: (root | path join CLAUDE.md)}
    }

    {args: $args, prep: $prep}
}

def prepare [prep: record] {
    for d in $prep.mkdirs { mkdir $d }
    for f in $prep.touches { touch $f }

    if not ($prep.seed.dst | path exists) {
        log info $'Seeding ($prep.seed.dst)'
        cp $prep.seed.src $prep.seed.dst
    }
}

def is-running []: nothing -> bool {
    (podman ps --filter $'name=^($NAME)$' --format '{{.Names}}' | str trim) == $NAME
}

def stop-container [] {
    if not (is-running) { return }

    log info $"Stopping container ($NAME)"
    podman stop $NAME | ignore
    remove-container
}

# The container is started without --rm so claude-attach can read its exit code
# after it ends (podman attach returns 0 whatever that code was); remove what is
# left of it before starting another under the same name
def remove-container [] {
    podman rm --ignore $NAME | complete | ignore
}

def ensure-container [plan: record] {
    if (is-running) {
        log debug $'Container ($NAME) is already running'
        return
    }

    log info $'Starting ($NAME) in the background'
    prepare $plan.prep
    remove-container

    try {
        podman run --detach --interactive --tty ...$plan.args $IMAGE | ignore
    } catch {|err|
        log debug $"podman run failed \(possibly already started concurrently\): ($err.msg)"
    }

    if not (is-running) {
        log error $'Failed to start container ($NAME)'
        exit 1
    }

    mounts apply (mounts-file) $NAME
    ports apply (ports-file) $NAME
}

def attach-zellij [fresh: bool] {
    $env.CLAUDE_CONTAINER = $NAME
    $env.CLAUDE_WRAPPER_DIR = root
    $env.CLAUDE_WRAPPER_ARGS = [] | to json --raw
    $env.CLAUDE_WRAPPER_UPDATING = runtime-dir | path join $"claude-wrapper-($NAME).updating"
    $env.PATH = $env.PATH | prepend ($SCRIPT_DIR | path join bin)

    # The layout is a template: the status bar's key hints come from the keybinds
    # in config.kdl at every launch, so they can't go stale. Written next to its
    # final name and renamed into place, so a concurrent launch never reads a
    # half-written file.
    let config = $SCRIPT_DIR | path join zellij config.kdl
    let layout = runtime-dir | path join $"claude-wrapper-($NAME).layout.kdl"
    let partial = $"($layout).($nu.pid)"
    hints render-layout ($SCRIPT_DIR | path join zellij layout.kdl) (hints keybinds $config) | save -f $partial
    mv -f $partial $layout

    let args = [
        --config $config
        options
        --default-layout $layout
        --session-name $NAME
        --attach-to-session true
    ]

    mut existing = do { zellij list-sessions --short --no-formatting } | complete | get stdout | lines
    if $fresh and $NAME in $existing {
        log info $"Ending Zellij session '($NAME)' to start a fresh one"
        zellij kill-session $NAME
        zellij delete-session $NAME | complete | ignore
        $existing = $existing | where $it != $NAME
    }

    if $NAME in $existing {
        log info $"Attaching to existing Zellij session '($NAME)'; run with -R for a fresh one \(e.g. after layout changes)"
    } else {
        log info $"Creating Zellij session '($NAME)'"
    }

    cd (root)
    # Panes run c/run.nu again; let them bootstrap on their own if the store path is gone
    hide-env -i CLAUDE_WRAPPER_FLAKE
    exec zellij ...$args
}

def main [
    --dryrun # Print the planned disk changes and podman arguments without touching anything
    --build # Build the container image first
    --shell(-s) # Open a plain shell in the container instead of the Zellij session
    --detach(-d) # Just make sure the container is running in the background; don't attach to Zellij
    --no-zellij(-Z) # Attach straight to Claude with podman attach (detach: Ctrl+P Ctrl+Q) instead of through Zellij
    --restart(-R) # Replace the Zellij session with a fresh one, e.g. to pick up layout changes (Claude keeps running)
    --restart-container # Stop and recreate the container so a rebuilt image applies (Claude resumes with --continue); implies --restart
] {
    if $build {
        just -f ($SCRIPT_DIR | path join justfile) build
    }

    let notify_socket = if $dryrun { null } else { ensure-notify-proxy }
    let plan = plan $notify_socket (wayland-socket)

    if $dryrun {
        print ($plan.prep | table --expand)
        print ($plan.args | str join "\n")
        return
    }

    if $restart_container { stop-container }
    ensure-container $plan
    if $detach { return }

    if $shell {
        exec podman exec -it $NAME /usr/local/bin/nu
    }
    if $no_zellij {
        exec ($SCRIPT_DIR | path join bin claude-attach) $NAME
    }
    attach-zellij ($restart or $restart_container)
}

def "main clone" [
    url: string # Repository to bare-clone into ~/claude/.bare
    name?: string # Repository name; defaults to the url's basename
] {
    host-only
    let repo = clone (root | path join .bare) $url $name
    log info $'Cloned into ($repo)'
}

def "main mount" [
    path: path # Host path to bind into the Manager at the same path
    mode: string = ro # ro (the default) or rw: bind read-only or read-write
] {
    host-only
    if $mode not-in $mounts.MODES {
        error make {msg: $"mount mode must be one of ($mounts.MODES | str join '|'), not '($mode)'"}
    }
    mounts add (mounts-file) $NAME $path $mode
}

def "main unmount" [
    path: path # A path added with `mount`
] {
    host-only
    mounts remove (mounts-file) $NAME $path
}

def "main mounts" [] {
    host-only
    mounts list (mounts-file) $NAME
}

def "main port" [] {
    print (help main port)
}

# Options are iproute2-style `<keyword> <value>` pairs, e.g. `c port open 8080 scope lan`
def "main port open" [
    spec: string # <port> or <host>:<container>[/tcp|/udp]
    ...options: string # [from container|host] [scope host|lan]
] {
    host-only
    let opts = keywords parse $options {from: $ports.FROM, scope: $ports.SCOPE}
    ports open (ports-file) $NAME $spec $opts.from $opts.scope
}

def "main port close" [
    spec: string # <port> or <host>:<container>[/tcp|/udp]
    ...options: string # [from container|host]: close a relay opened `from host`
] {
    host-only
    let opts = keywords parse $options {from: $ports.FROM}
    ports close (ports-file) $spec $opts.from
}

def "main ports" [] {
    host-only
    ports list (ports-file)
}

# A frame of Claude's Emacs (the `emacs` service) on this display, with the
# host's emacsclient; starts the service first when it is not running
def "main emacs" [
    file?: path # File to visit
    line?: int # Line to go to
] {
    host-only
    let target = [$file $line] | compact | each { into string }
    nu ($SCRIPT_DIR | path join bin claude-emacs) frame ...$target
}

def "main usage" [
    --since: duration # Only samples newer than this, e.g. 2day or 6hr (default: all)
    --last(-n): int = 15 # Rows in the latest-samples table
    --width(-w): int = 60 # Sparkline width in characters
    --json # Print the samples and per-day series as JSON instead of a report
] {
    host-only
    let file = state | path join claude usage.jsonl
    let flags = [
        ...(if $since == null { [] } else { [--since $"($since | into int)ns"] })
        --last $last
        --width $width
        ...(if $json { [--json] } else { [] })
    ]
    nu ($SCRIPT_DIR | path join bin claude-usage) $file ...$flags
}
