#!/usr/bin/env nu

# $env.NU_LOG_LEVEL = "DEBUG"
use std/log

const SCRIPT_DIR: string = path self | path expand | path dirname
# Claude runs as root in the container, so its scratchpads live here
const SCRATCH_ROOT = "/tmp/claude-0"

# The launcher only runs for, and --rw only mounts, directories under this
def workspace-root []: nothing -> path { $env.HOME | path join workspaces }

# Whether `dir` is strictly inside `root` (by path, not string prefix)
def is-inside [dir: path, root: path]: nothing -> bool {
    try { $dir | path expand | path relative-to $root | is-not-empty } catch { false }
}

# Warn if the git dir has been redirected somewhere else. With --git-write the
# container can write these pointer files, and host-side git follows them
# (including to a config with e.g. core.fsmonitor set, which runs code).
def check-git-pointers [commondir: path] {
    if ($commondir | path join commondir | path exists) {
        log warning $'Unexpected (ansi yellow_bold)($commondir)/commondir(ansi reset), inspect before running git on the host'
    }
    let worktrees = $commondir | path join worktrees
    if not ($worktrees | path exists) { return }
    for wt in (ls $worktrees | where type == dir | get name) {
        let pointer = $wt | path join commondir
        if not ($pointer | path exists) { continue }
        let target = $wt | path join (open --raw $pointer | str trim) | path expand
        if $target != ($commondir | path expand) {
            log warning $'(ansi yellow_bold)($pointer)(ansi reset) points to ($target), inspect before running git on the host'
        }
    }
}

# Claude Code's per-project key for a path: every non-alphanumeric becomes '-'.
def claude-key [dir: path]: nothing -> string {
    $dir | str replace --all --regex '[^A-Za-z0-9]' '-'
}

# How `dir` relates to git and ~/workspaces, from a single git call.
# `group` is what Claude state is split by: the repo's common git dir (shared
# by all its worktrees), or the directory itself outside git.
def project-info [dir: path]: nothing -> record {
    let relpath = try {
        $dir | path expand | path relative-to (workspace-root)
    } catch { "" }
    let git = do {
        git -C $dir rev-parse --show-toplevel --absolute-git-dir --path-format=absolute --git-common-dir
    } | complete

    if $git.exit_code != 0 {
        return {
            dir: $dir, relpath: $relpath, key: (claude-key $dir), group: (claude-key $dir)
            is_git: false, is_worktree: false, is_treebundel: false
            toplevel: null, gitdir: null, commondir: null
        }
    }
    let toplevel = $git.stdout | lines | get 0
    let is_worktree = ($toplevel | path join .git | path type) == file
    {
        dir: $dir, relpath: $relpath, key: (claude-key $dir)
        group: (claude-key ($git.stdout | lines | get 2))
        is_git: true
        is_worktree: $is_worktree
        is_treebundel: ($is_worktree and ($relpath | path split | length) >= 2)
        toplevel: $toplevel
        gitdir: ($git.stdout | lines | get 1)
        commondir: ($git.stdout | lines | get 2)
    }
}

# A mount of `path` at the same path inside the container.
def bind [path: path, mode: string]: nothing -> record {
    {src: $path, dst: $path, mode: $mode}
}

# Read-write mount of the repo's common git dir (config included), plus read-only
# mounts over hooks/ and the per-worktree pointers unless those are allowed too.
def git-write-mounts [commondir: path, write_hooks: bool, write_worktrees: bool]: nothing -> record {
    let hooks = if $write_hooks { [] } else { [($commondir | path join hooks)] }

    let worktrees = $commondir | path join worktrees
    let worktree_files = if $write_worktrees or not ($worktrees | path exists) { [] } else {
        ls $worktrees
        | where type == dir
        | get name
        | each {|wt| [commondir gitdir config.worktree] | each {|f| $wt | path join $f } }
        | flatten
        | where {|f| $f | path exists }
    }

    {
        mounts: ([(bind $commondir rw)] | append ([...$hooks ...$worktree_files] | each {|p| bind $p ro }))
        # hooks/ may not exist yet, but must to be mounted over
        mkdirs: $hooks
    }
}

# What to mount for the project in `info`, and the container's name and prompt.
def mount-points [info: record, git_write: bool, write_hooks: bool, write_worktrees: bool]: nothing -> record {
    log debug $'is_git        ($info.is_git)'
    log debug $'is_worktree   ($info.is_worktree)'
    log debug $'is_treebundel  ($info.is_treebundel)'

    mut plan = {
        name: ($info.dir | path basename)
        PS1: $'(ansi white_bold)\h(ansi reset)$ '
        workdir: $info.dir
        mounts: [(bind $info.dir rw)]
        mkdirs: []
    }

    # A regular git project
    if $info.is_git {
        log info $'Opening as a git project'
        $plan.name = $info.toplevel | path basename
        $plan.PS1 = $'(ansi white_dimmed)\h(ansi reset)$ '
        if $git_write {
            log info $'Allowing writes to ($info.commondir)'
            let git_mounts = git-write-mounts $info.commondir $write_hooks $write_worktrees
            $plan.mounts ++= $git_mounts.mounts
            $plan.mkdirs ++= $git_mounts.mkdirs
        } else {
            $plan.mounts ++= [(bind $info.gitdir ro)]
        }
    }
    if $info.is_worktree {
        $plan.mounts ++= [(bind ($info.toplevel | path join .git) ro)]
    }

    # A managed treebundel project
    if $info.is_treebundel {
        log info $'Opening as treebundel project'

        let workspace = $info.relpath | path split | get 0
        let project = $info.relpath | path split | get 1
        $plan.name = $'($workspace)-($project)'
        $plan.PS1 = $'🪾(ansi blue_bold)($workspace)(ansi reset)/(ansi green_bold)($project)(ansi reset)$ '
        $plan.mounts ++= [(bind ($env.HOME | path join workspaces .bare) ro)]
    }

    $plan
}

# Filtered session-bus socket that only allows talking to the notification
# service, so containers can raise desktop notifications without full D-Bus
# access. One proxy (a transient systemd user unit) is shared by all containers.
# Returns the socket path, or null if notifications aren't available.
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

# Disk changes the mount plan depends on. Only made when a container is
# actually started, so nothing moves under a running one.
def prepare [prep: record] {
    for d in $prep.mkdirs { mkdir $d }
    for f in $prep.touches { touch $f }
    for m in $prep.moves {
        log info $'Moving ($m.src) to ($m.dst)'
        mkdir ($m.dst | path dirname)
        mv $m.src $m.dst
    }
    # Mount points podman made for other projects' entries in earlier runs
    for d in $prep.prune {
        ls $d | where type == dir | get name | each {|e| ^rmdir --ignore-fail-on-non-empty $e } | ignore
    }
}

def is-running [name: string]: nothing -> bool {
    (podman ps --filter $'name=^($name)$' --format '{{.Names}}' | str trim) == $name
}

# Stop the container (it's run with --rm, so it's also removed) and wait for it
# to be gone, so ensure-container can start a fresh one under the same name.
def stop-container [name: string] {
    if not (is-running $name) { return }
    log info $"Stopping container ($name)"
    podman stop $name | ignore
    for _ in 1..100 {
        if (do { podman container exists $name } | complete).exit_code != 0 { return }
        sleep 100ms
    }
    log error $"Container ($name) is still there after stopping"
    exit 1
}

def ensure-container [image: string, args: list<string>, name: string, prep: record] {
    if (is-running $name) {
        log debug $'Container ($name) is already running'
        return
    }

    log info $'Starting ($name) in the background'
    prepare $prep
    try {
        podman run --detach --interactive --tty --rm ...$args $image sh -c "claude --continue || claude" | ignore
    } catch { |err|
        # Might just be a lost race with another invocation starting the same
        # container; the check below is what actually decides success.
        log debug $"podman run failed \(possibly already started concurrently\): ($err.msg)"
    }

    if not (is-running $name) {
        log error $'Failed to start container ($name)'
        exit 1
    }
}

# Subdirectories of `dir` that have something in them; empty ones are left-over
# mount points, not real entries.
def entries [dir: path]: nothing -> list<path> {
    if not ($dir | path exists) { return [] }
    ls $dir | where type == dir | get name | where {|d| ls --all $d | is-not-empty }
}

# Per-project slices of Claude's state, so containers don't see each other's
# transcripts, memory or scratchpads. Each group (see project-info) gets its
# own store for ~/.claude/projects and the scratchpad root (SCRATCH_ROOT),
# mounted at the same paths Claude uses. With `others` set to ro/rw, every other group's entries are mounted
# into those same dirs too.
def claude-state-plan [state_dir: path, info: record, others: string]: nothing -> record {
    let group = $info.group
    let stores = [
        {root: ($state_dir | path join projects), dst: ($env.HOME | path join .claude projects)}
        {root: ($state_dir | path join scratch), dst: $SCRATCH_ROOT}
    ] | each {|s| $s | insert own ($s.root | path join $group) }

    # Transcripts and memory used to live in the shared ~/.claude/projects;
    # move this group's entries into its own store.
    let legacy = entries ($state_dir | path join claude projects)
    let moves = $legacy
    | where {|p| let k = $p | path basename; ($k | str starts-with $group) or ($k | str starts-with $info.key) }
    | each {|src| {src: $src, dst: ($stores.0.own | path join ($src | path basename))} }
    | where {|m|
        if ($m.dst | path exists) { log warning $'Not migrating ($m.src): ($m.dst) already exists' }
        not ($m.dst | path exists)
    }

    let mounts = $stores | each {|s|
        let mine = [{src: $s.own, dst: $s.dst, mode: rw}]
        if $others == none { return $mine }

        let mine_keys = entries $s.own
        | append (if $s.own == $stores.0.own { $moves | get dst } else { [] })
        | path basename
        let theirs = entries $s.root
        | where $it != $s.own
        | each {|g| entries $g }
        | flatten
        | append (if $s.own == $stores.0.own { $legacy } else { [] })
        | where {|src| ($src | path basename) not-in $mine_keys }
        | each {|src| {src: $src, dst: ($s.dst | path join ($src | path basename)), mode: $others} }
        $mine | append $theirs
    } | flatten | uniq-by dst

    {
        mounts: $mounts
        mkdirs: ($stores | get own)
        moves: $moves
        prune: ($stores | get own)
    }
}

# Collect the repeatable mount options (`--rw <dir>`, `--rwf <dir>`, `-r <dir>`,
# also as `--rw=<dir>` etc.) that `main` receives unparsed via --wrapped.
def parse-mount-args [args: list<string>]: nothing -> record {
    mut parsed = {rw: [], rwf: [], ro: []}
    mut i = 0
    while $i < ($args | length) {
        let arg = $args | get $i
        if $arg in [--help -h] {
            print (help main)
            exit 0
        }
        let parts = $arg | split row --number 2 '='
        let flag = $parts.0
        let key = {"--rw": rw, "--rwf": rwf, "-r": ro} | get --optional $flag
        if $key == null {
            log error $'Unknown argument (ansi light_red_bold)($arg)(ansi reset)'
            exit 1
        }
        let value = if ($parts | length) == 2 {
            # --wrapped passes `--rw="a b"` through with its quotes still on
            $parts.1 | str trim --char '"' | str trim --char "'"
        } else {
            $i += 1
            $args | get --optional $i
        }
        if ($value | is-empty) {
            log error $'($flag) needs a directory'
            exit 1
        }
        $parsed = $parsed | update $key { append $value }
        $i += 1
    }

    # Podman fails on a missing source, and --rw keeps writes inside ~/workspaces
    # unless --rwf asks otherwise.
    for dir in ($parsed.rw | path expand) {
        if not (is-inside $dir (workspace-root)) or ($dir | path type) != dir {
            log error $'--rw ($dir) must be a directory inside (ansi light_red_bold)~/workspaces/(ansi reset)'
            exit 1
        }
    }
    for dir in ($parsed.rwf | path expand) {
        if ($dir | path type) != dir {
            log error $'--rwf ($dir) must be a directory'
            exit 1
        }
    }
    for p in ($parsed.ro | path expand) {
        if not ($p | path exists) {
            log error $"-r ($p) doesn't exist"
            exit 1
        }
    }
    {
        rw: ($parsed.rw | append $parsed.rwf | path expand)
        ro: ($parsed.ro | path expand)
    }
}

# Attach to the container's host-side Zellij session, creating it if needed.
# Panes run podman against the container named by CLAUDE_CONTAINER; Zellij's
# default shell (bin/claude-container-shell) is a shell inside it.
def attach-zellij [name: string, fresh: bool, launch_args: list<string>] {
    $env.CLAUDE_CONTAINER = $name
    # For bin/claude-update, and bin/claude-attach to know when it's running
    $env.CLAUDE_WRAPPER_DIR = pwd
    $env.CLAUDE_WRAPPER_UPDATING = $env.XDG_RUNTIME_DIR? | default "" | if ($in | is-empty) { "/tmp" } else { $in } | path join $"claude-wrapper-($name).updating"
    $env.CLAUDE_WRAPPER_ARGS = $launch_args | to json --raw
    $env.PATH = $env.PATH | prepend ($SCRIPT_DIR | path join bin)
    # The layout only applies when the session is created; otherwise this attaches.
    # These `options` flags work across Zellij versions, unlike --new-session-with-layout.
    let args = [
        --config ($SCRIPT_DIR | path join zellij config.kdl)
        options
        --default-layout ($SCRIPT_DIR | path join zellij layout.kdl)
        --session-name $name
        --attach-to-session true
    ]
    mut existing = do { zellij list-sessions --short --no-formatting } | complete | get stdout | lines
    if $fresh and $name in $existing {
        log info $"Ending Zellij session '($name)' to start a fresh one"
        zellij kill-session $name
        zellij delete-session $name | complete | ignore
        $existing = $existing | where $it != $name
    }
    if $name in $existing {
        log info $"Attaching to existing Zellij session '($name)'; run with -R for a fresh one \(e.g. after layout changes)"
    } else {
        log info $"Creating Zellij session '($name)'"
    }
    log info $"zellij ($args | str join ' ')"
    exec zellij ...$args
}

def --wrapped main [
    --dryrun
    --build
    --shell(-s) # Open a plain shell in the container instead of the Zellij session
    --detach(-d) # Just make sure the container is running in the background; don't attach to Zellij
    --no-zellij(-Z) # Attach straight to Claude with podman attach (detach: Ctrl+P Ctrl+Q) instead of through Zellij
    --restart(-R) # Replace this project's Zellij session with a fresh one, e.g. to pick up layout changes (Claude keeps running)
    --restart-container # Stop and recreate the container so new mounts or a rebuilt image apply (Claude resumes with --continue); implies --restart
    --git-write(-g) # Let the container commit/branch/etc. (hooks/ and worktrees/ files stay read-only unless allowed below)
    --git-write-hooks(-H) # Also make hooks/ writable (implies --git-write)
    --git-write-worktrees(-w) # Also make the per-worktree files under worktrees/ writable (implies --git-write)
    --claude-read-others(-c) # Mount other projects' Claude transcripts, memory and scratchpads read-only
    --claude-write-others(-C) # Same as --claude-read-others, but read-write
    --host-network # Share the host's network so Claude can reach services on its localhost (e.g. Minecraft MCP mods); exposes all of them
    ...args: string # --rw <dir> (repeatable): mount a directory under ~/workspaces read-write at the same path; --rwf <dir> (repeatable): same as --rw but anywhere on the host; -r <dir> (repeatable): mount a directory read-only at the same path
] {
    if $build {
        just -f $'($SCRIPT_DIR)/justfile' build
    }

    log debug $"SCRIPT_DIR: ($SCRIPT_DIR)"
    let extra = parse-mount-args $args
    if (pwd) != (workspace-root) and not (is-inside (pwd) (workspace-root)) {
        log error $'Can only use in (ansi light_red_bold)~/workspaces/(ansi reset)'
        exit 1
    }
    # The hooks/worktrees write options only make sense with git writes
    let git_write = $git_write or $git_write_hooks or $git_write_worktrees
    # How this container was launched, so Ctrl+Space U can recreate it the same way
    let launch_args = [
        ...(if $git_write { [--git-write] } else { [] })
        ...(if $git_write_hooks { [--git-write-hooks] } else { [] })
        ...(if $git_write_worktrees { [--git-write-worktrees] } else { [] })
        ...(if $claude_read_others { [--claude-read-others] } else { [] })
        ...(if $claude_write_others { [--claude-write-others] } else { [] })
        ...(if $host_network { [--host-network] } else { [] })
        ...$args
    ]

    let info = project-info (pwd)
    if $info.is_git { check-git-pointers $info.commondir }
    let plan = mount-points $info $git_write $git_write_hooks $git_write_worktrees

    # Host-side storage for the container's Claude Code config/auth. Claude
    # only runs inside the container, so this stays out of the host's ~/.claude.
    let state_dir = $env.XDG_DATA_HOME? | default ($env.HOME | path join .local share) | path join claude-wrapper
    let others = if $claude_write_others { "rw" } else if $claude_read_others { "ro" } else { "none" }
    let claude_state = claude-state-plan $state_dir $info $others

    let notify_socket = if $dryrun { null } else { ensure-notify-proxy }

    let mounts = [
        ...$plan.mounts
        ...($extra.rw | each {|d| bind $d rw })
        ...($extra.ro | each {|d| bind $d ro })
        {src: ($state_dir | path join claude), dst: ($env.HOME | path join .claude), mode: rw}
        {src: ($state_dir | path join claude.json), dst: ($env.HOME | path join .claude.json), mode: rw}
        ...$claude_state.mounts
        # gh's login (hosts.yml), kept alongside Claude's state
        {src: ($state_dir | path join gh), dst: ($env.HOME | path join .config gh), mode: rw}
        ...(if $notify_socket == null { [] } else { [{src: $notify_socket, dst: /run/claude-bus, mode: rw}] })
    ]
    let prep = {
        mkdirs: [
            ...$plan.mkdirs
            ($state_dir | path join claude)
            ($state_dir | path join gh)
            ...$claude_state.mkdirs
        ]
        touches: [($state_dir | path join claude.json)]
        moves: $claude_state.moves
        prune: $claude_state.prune
    }

    let args = [
        --name=($plan.name)
        --env
        PS1=($plan.PS1)
        --env
        ENABLE_LSP_TOOL=1
        # Match the host's HOME so the absolute paths Claude Code records
        # (plugin/marketplace locations, project keys) line up with the mounts.
        --env
        HOME=($env.HOME)
        ...(if $notify_socket == null { [] } else { [--env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/claude-bus] })
        ...($mounts | each {|m| $'--volume=($m.src):($m.dst):($m.mode)' })
        # Persist the nix store and flake/tarball cache across containers
        --volume=claude-nix:/nix
        $'--volume=claude-nix-cache:($env.HOME)/.cache/nix'
        $'--volume=claude-code:($env.HOME)/.local/share/claude'
        $'--volume=claude-code-bin:($env.HOME)/.local/bin'
        # Nix's builder needs the /proc paths podman masks by default
        --security-opt=unmask=/proc/*
        --workdir=($plan.workdir)
        # Host networking also uses the host's hostname, which podman may refuse to override
        ...(if $host_network { [--network=host] } else { [--hostname=($plan.name)] })
    ]

    if $dryrun {
        print ($prep | table --expand)
        print $args
        return
    }

    if $restart_container { stop-container $plan.name }
    ensure-container 'claude' $args $plan.name $prep
    if $detach { return }

    if $shell {
        exec podman exec -it $plan.name bash
    }
    if $no_zellij {
        exec ($SCRIPT_DIR | path join bin claude-attach) $plan.name
    }
    attach-zellij $plan.name ($restart or $restart_container) $launch_args
}
