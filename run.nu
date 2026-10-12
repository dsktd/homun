#!/usr/bin/env nu

# $env.NU_LOG_LEVEL = "DEBUG"
use std/log

const SCRIPT_DIR: string = path self | path expand | path dirname
const DRY_RUN: bool = true
let restrict_to_prefix = $"($env.HOME | path join workspaces)"
log debug $"SCRIPT_DIR: ($SCRIPT_DIR)"
log debug $"DRY_RUN: ($DRY_RUN)"
log debug $"restrict_to_prefix: ($restrict_to_prefix)"

let is_path_allowed = pwd | str starts-with $restrict_to_prefix
log debug $"is path allowed: ($is_path_allowed)"

if not $is_path_allowed {
    log error $'Can only use in (ansi light_red_bold)~/workspaces/(ansi reset)'
    exit 1
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

# Read-write mount of the repo's common git dir (config included), plus read-only
# mounts over hooks/ and the per-worktree pointers unless those are allowed too.
def git-write-mounts [commondir: path, write_hooks: bool, write_worktrees: bool]: nothing -> record {
    let hooks = if $write_hooks { [] } else {
        let hooks = $commondir | path join hooks
        mkdir $hooks
        [$hooks]
    }

    let worktrees = $commondir | path join worktrees
    let worktree_files = if $write_worktrees or not ($worktrees | path exists) { [] } else {
        ls $worktrees
        | where type == dir
        | get name
        | each {|wt| [commondir gitdir config.worktree] | each {|f| $wt | path join $f } }
        | flatten
        | where {|f| $f | path exists }
    }

    let protected = [...$hooks ...$worktree_files]
    {
        readonly: ($protected | each {|p| {src: $p, dst: $p} })
        readwrite: [{src: $commondir, dst: $commondir}]
    }
}

def mount-points [current_dir: path, git_write: bool, write_hooks: bool, write_worktrees: bool]: nothing -> record {
    let workspace_path = $env.HOME | path join "workspaces"
    let is_git = git rev-parse --show-toplevel | ignore -e | into bool --relaxed
    let is_worktree = (
        $is_git and ((git rev-parse --show-toplevel | path join ".git" | path type) == file)
    )

    let relpath = try {
        $current_dir | path expand | (path relative-to $workspace_path)
    } catch { "" }
    let is_treebundel = $is_worktree and ($relpath | path split | length) >= 2

    log debug $'is_git        ($is_git)'
    log debug $'is_worktree   ($is_worktree)'
    log debug $'is_treebundel  ($is_treebundel)'

    mut docker = {
        name: ($current_dir | path basename)
        PS1: $'(ansi white_bold)\h(ansi reset)$ '
        readonly: []
        readwrite: [[src, dst]; [$current_dir, $current_dir]]
        workdir: $current_dir
    }

    # A regular git project
    if $is_git {
        log info $'Opening as a git project'

        let gitdir = git rev-parse --absolute-git-dir
        let commondir = git rev-parse --path-format=absolute --git-common-dir
        let toplevel = git rev-parse --show-toplevel
        check-git-pointers $commondir
        $docker = $docker | merge {
            name: ($toplevel | path basename)
            PS1: $'(ansi white_dimmed)\h(ansi reset)$ '
        }
        if $git_write {
            log info $'Allowing writes to ($commondir)'
            let git_mounts = git-write-mounts $commondir $write_hooks $write_worktrees
            $docker = $docker | merge {
                readonly: ($docker.readonly | append $git_mounts.readonly)
                readwrite: ($docker.readwrite | append $git_mounts.readwrite)
            }
        } else {
            $docker = $docker | merge {
                readonly: ($docker.readonly | append [[src, dst];[$gitdir $gitdir]])
            }
        }
    }
    if $is_worktree {
        let gitfile = [
            (git rev-parse --show-toplevel)
            ".git"
        ] | path join
        $docker = $docker | merge {
            readonly: ($docker.readonly | append [[src, dst];[$gitfile $gitfile]])
        }
    }

    # A managed treebundel project
    if $is_treebundel {
        log info $'Opening as treebundel project'

        let workspace = $relpath | path split | get 0
        let project = $relpath | path split | get 1
        $docker = $docker | merge {
            name: $'($workspace)-($project)'
            PS1: $'🪾(ansi blue_bold)($workspace)(ansi reset)/(ansi green_bold)($project)(ansi reset)$ '
            readonly: ($docker.readonly | append [[src, dst];[($env.HOME + "/workspaces/.bare") ($env.HOME + "/workspaces/.bare")]])
        }
    }

    $docker
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

def ensure-container [image: string, args: list<string>, name: string, state_dir: path] {
    let running = (podman ps --filter $'name=^($name)$' --format '{{.Names}}' | str trim) == $name
    if $running {
        log debug $'Container ($name) is already running'
        return
    }

    log info $'Starting ($name) in the background'
    mkdir ($state_dir | path join claude)
    touch ($state_dir | path join claude.json)
    mkdir ($state_dir | path join gh)
    try {
        podman run --detach --interactive --tty --rm ...$args $image sh -c "claude --continue || claude" | ignore
    } catch { |err|
        # Might just be a lost race with another invocation starting the same
        # container; the check below is what actually decides success.
        log debug $"podman run failed \(possibly already started concurrently\): ($err.msg)"
    }

    let started = (podman ps --filter $'name=^($name)$' --format '{{.Names}}' | str trim) == $name
    if not $started {
        log error $'Failed to start container ($name)'
        exit 1
    }
}

# Claude Code's per-project key for a path: every non-alphanumeric becomes '-'.
def claude-key [dir: path]: nothing -> string {
    $dir | str replace --all --regex '[^A-Za-z0-9]' '-'
}

# Per-project slices of Claude's state, so containers don't see each other's
# transcripts, memory or scratchpads. A "group" is a repo (keyed by its common
# git dir, which all its worktrees share) or a plain directory. Each group gets
# its own store for ~/.claude/projects and the scratchpad root /tmp/claude-0
# (claude runs as root in the container), mounted at the same paths Claude
# uses. With `others` set to ro/rw, every other group's entries are mounted
# into those same dirs too.
def claude-state-mounts [state_dir: path, others: string, dryrun: bool]: nothing -> list<record> {
    let cwd_key = claude-key (pwd)
    let is_git = (do { git rev-parse --git-common-dir } | complete).exit_code == 0
    let group = if $is_git {
        claude-key (git rev-parse --path-format=absolute --git-common-dir)
    } else { $cwd_key }

    let stores = [
        {dir: projects, dst: ($env.HOME | path join .claude projects)}
        {dir: scratch, dst: /tmp/claude-0}
    ] | each {|s| $s | insert root ($state_dir | path join $s.dir) }

    # Transcripts and memory used to live in the shared ~/.claude/projects;
    # move this group's entries into its own store.
    let legacy = $state_dir | path join claude projects
    let own_projects = $stores.0.root | path join $group
    if ($legacy | path exists) {
        let entries = ls $legacy | where type == dir | get name | where {|p|
            let k = $p | path basename
            ($k | str starts-with $group) or ($k | str starts-with $cwd_key)
        }
        for src in $entries {
            let dst = $own_projects | path join ($src | path basename)
            if ($dst | path exists) {
                log warning $'Not migrating ($src): ($dst) already exists'
            } else if $dryrun {
                log info $'Would move ($src) to ($dst)'
            } else {
                log info $'Moving ($src) to ($dst)'
                mkdir $own_projects
                mv $src $dst
            }
        }
    }

    $stores | each {|s|
        let own = $s.root | path join $group
        if not $dryrun {
            mkdir $own
            # Mount points made for other groups' entries in a previous run
            ls $own | where type == dir | get name | each {|d| ^rmdir --ignore-fail-on-non-empty $d } | ignore
        }
        let mine = [{src: $own, dst: $s.dst, mode: rw}]
        if $others == none or not ($s.root | path exists) { return $mine }

        let mine_keys = if ($own | path exists) { ls $own | get name | path basename } else { [] }
        let theirs = ls $s.root
        | where type == dir and ($it.name | path basename) != $group
        | get name
        | each {|g| ls $g | where type == dir | get name }
        | flatten
        | where {|src| ($src | path basename) not-in $mine_keys }
        | each {|src| {src: $src, dst: ($s.dst | path join ($src | path basename)), mode: $others} }
        let legacy_theirs = if $s.dir == projects and ($legacy | path exists) {
            ls $legacy | where type == dir | get name
            | where {|src| ($src | path basename) not-in $mine_keys }
            | each {|src| {src: $src, dst: ($s.dst | path join ($src | path basename)), mode: $others} }
        } else { [] }
        $mine | append $theirs | append $legacy_theirs
    } | flatten | uniq-by dst
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
    $parsed
}

def --wrapped main [
    --dryrun
    --build
    --shell(-s)
    --detach(-d) # Just make sure the container is running in the background; don't attach
    --git-write(-g) # Let the container commit/branch/etc. (hooks/ and worktrees/ files stay read-only unless allowed below)
    --git-write-hooks(-H) # With --git-write, also make hooks/ writable
    --git-write-worktrees(-w) # With --git-write, also make the per-worktree files under worktrees/ writable
    --claude-read-others(-c) # Mount other projects' Claude transcripts, memory and scratchpads read-only
    --claude-write-others(-C) # Same as --claude-read-others, but read-write
    ...args: string # --rw <dir> (repeatable): mount a directory under ~/workspaces read-write at the same path; --rwf <dir> (repeatable): same as --rw but anywhere on the host; -r <dir> (repeatable): mount a directory read-only at the same path
] {
    if $build {
        just -f $'($SCRIPT_DIR)/justfile' build
    }

    let extra = parse-mount-args $args
    let workspace_path = $env.HOME | path join workspaces
    let extra_rw = $extra.rw | path expand
    for dir in $extra_rw {
        let inside = try { $dir | path relative-to $workspace_path | is-not-empty } catch { false }
        if not $inside or ($dir | path type) != dir {
            log error $'--rw ($dir) must be a directory inside (ansi light_red_bold)~/workspaces/(ansi reset)'
            exit 1
        }
    }

    let extra_rwf = $extra.rwf | path expand
    for dir in $extra_rwf {
        if ($dir | path type) != dir {
            log error $'--rwf ($dir) must be a directory'
            exit 1
        }
    }
    let mounts = mount-points (pwd) $git_write $git_write_hooks $git_write_worktrees
    # Host-side storage for the container's Claude Code config/auth. Claude
    # only runs inside the container, so this stays out of the host's ~/.claude.
    let state_dir = $env.XDG_DATA_HOME? | default ($env.HOME | path join .local share) | path join claude-wrapper

    let others = if $claude_write_others { "rw" } else if $claude_read_others { "ro" } else { "none" }
    let claude_state = claude-state-mounts $state_dir $others $dryrun

    let notify_socket = if $dryrun { null } else { ensure-notify-proxy }
    let notify_args = if $notify_socket == null { [] } else {
        [
            $'--volume=($notify_socket):/run/claude-bus'
            --env
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/claude-bus
        ]
    }

    let args = [
        ...$notify_args
        --name=($mounts.name)
        --env
        PS1=($mounts.PS1)
        --env
        ENABLE_LSP_TOOL=1
        # Match the host's HOME so the absolute paths Claude Code records
        # (plugin/marketplace locations, project keys) line up with the mounts.
        --env
        HOME=($env.HOME)
        ...(
            $mounts.readonly
            | each {|v| "--volume=" + $v.src + ":" + $v.dst + ":ro"}
        )
        ...(
            $mounts.readwrite | append ($extra_rw | append $extra_rwf | each {|d| {src: $d, dst: $d} })
            | each {|v| "--volume=" + $v.src + ":" + $v.dst + ":rw"}
        )
        ...(
            $extra.ro | path expand
            | each {|v| $'--volume=($v):($v):ro'}
        )
        $'--volume=($state_dir)/claude:($env.HOME)/.claude'
        $'--volume=($state_dir)/claude.json:($env.HOME)/.claude.json'
        ...($claude_state | each {|v| $'--volume=($v.src):($v.dst):($v.mode)'})
        # gh's login (hosts.yml), kept alongside Claude's state
        $'--volume=($state_dir)/gh:($env.HOME)/.config/gh'
        # Persist the nix store and flake/tarball cache across containers
        --volume=claude-nix:/nix
        $'--volume=claude-nix-cache:($env.HOME)/.cache/nix'
        --workdir=($mounts.workdir)
        --hostname=($mounts.name)
    ]

    if $dryrun {
        print $args
        return
    }

    ensure-container 'claude' $args $mounts.name $state_dir
    if $detach { return }

    if $shell {
        exec podman exec -it $mounts.name bash
    } else {
        exec podman attach $mounts.name
    }
}
