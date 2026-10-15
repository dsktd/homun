#!/usr/bin/env nu
# Launcher for the Manager container. Host-only subcommands refuse to run where
# /run/.containerenv exists; CLAUDE_WRAPPER_CONTAINERENV points them at another
# marker file (the test suite uses it to run inside the container).

use std/log

const SCRIPT_DIR: string = path self | path expand | path dirname
const LIB = $SCRIPT_DIR | path join lib

use ($LIB | path join clone.nu)
use ($LIB | path join mounts.nu)
use ($LIB | path join ports.nu)

const NAME = "claude-manager"
const IMAGE = "claude"
const SCRATCH = "/tmp/claude-0"

def root []: nothing -> path { $env.HOME | path join claude }

def state []: nothing -> path { $env.HOME | path join .local share claude }

def config []: nothing -> path { $env.HOME | path join .config claude }

def mounts-file []: nothing -> path { config | path join mounts.nuon }

def ports-file []: nothing -> path { config | path join ports.nuon }

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

def plan [notify_socket: any]: nothing -> record {
    let state = state

    let mounts = [
        {src: (root), dst: (root), mode: rw}

        {src: ($state | path join claude), dst: ($env.HOME | path join .claude), mode: rw}
        {src: ($state | path join claude.json), dst: ($env.HOME | path join .claude.json), mode: rw}
        {src: ($state | path join gh), dst: ($env.HOME | path join .config gh), mode: rw}
        {src: ($state | path join scratch), dst: $SCRATCH, mode: rw}

        # Over the image's copy, so edits to the checkout show up on the next refresh
        {src: ($SCRIPT_DIR | path join statusline.sh), dst: /statusline.sh, mode: ro}

        ...(if $notify_socket == null { [] } else { [{src: $notify_socket, dst: /run/claude-bus, mode: rw}] })
    ]

    let args = [
        --name=($NAME)
        --hostname=($NAME)
        --workdir=(root)

        --env $'PS1=(ansi magenta_bold)\h(ansi reset)$ '
        --env ENABLE_LSP_TOOL=1
        --env HOME=($env.HOME)
        ...(if $notify_socket == null { [] } else { [--env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/claude-bus] })

        ...($mounts | each {|m| $'--volume=($m.src):($m.dst):($m.mode)' })
        --volume=claude-nix:/nix
        $'--volume=claude-nix-cache:($env.HOME)/.cache/nix'
        $'--volume=claude-code:($env.HOME)/.local/share/claude'
        $'--volume=claude-code-bin:($env.HOME)/.local/bin'

        --security-opt=unmask=/proc/*
    ]

    let prep = {
        mkdirs: [
            (root)
            (root | path join .bare)
            ($state | path join claude)
            ($state | path join gh)
            ($state | path join scratch)
        ]
        touches: [($state | path join claude.json)]
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

    for _ in 1..100 {
        if (do { podman container exists $NAME } | complete).exit_code != 0 { return }
        sleep 100ms
    }

    log error $"Container ($NAME) is still there after stopping"
    exit 1
}

def ensure-container [plan: record] {
    if (is-running) {
        log debug $'Container ($NAME) is already running'
        return
    }

    log info $'Starting ($NAME) in the background'
    prepare $plan.prep

    try {
        podman run --detach --interactive --tty --rm ...$plan.args $IMAGE | ignore
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
    $env.CLAUDE_WRAPPER_UPDATING = $env.XDG_RUNTIME_DIR? | default "" | if ($in | is-empty) { "/tmp" } else { $in } | path join $"claude-wrapper-($NAME).updating"
    $env.PATH = $env.PATH | prepend ($SCRIPT_DIR | path join bin)

    let args = [
        --config ($SCRIPT_DIR | path join zellij config.kdl)
        options
        --default-layout ($SCRIPT_DIR | path join zellij layout.kdl)
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
    let plan = plan $notify_socket

    if $dryrun {
        print ($plan.prep | table --expand)
        print ($plan.args | str join "\n")
        return
    }

    if $restart_container { stop-container }
    ensure-container $plan
    if $detach { return }

    if $shell {
        exec podman exec -it $NAME bash
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
    --rw # Mount read-write instead of read-only
] {
    host-only
    mounts add (mounts-file) $NAME $path --rw=$rw
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

def "main port open" [
    spec: string # <host>:<container>[/tcp|/udp]
    --from-host # Let the container reach the host's port instead of the other way round
] {
    host-only
    ports open (ports-file) $NAME $spec --from-host=$from_host
}

def "main port close" [
    spec: string # <host>:<container>[/tcp|/udp]
    --from-host # Close a relay opened with --from-host
] {
    host-only
    ports close (ports-file) $spec --from-host=$from_host
}

def "main ports" [] {
    host-only
    ports list (ports-file)
}
