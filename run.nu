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

def mount-points [current_dir: path]: nothing -> record {
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
        let toplevel = git rev-parse --show-toplevel
        $docker = $docker | merge {
            name: ($toplevel | path basename)
            PS1: $'(ansi white_dimmed)\h(ansi reset)$ '
            readonly: ($docker.readonly | append [[src, dst];[$gitdir $gitdir]])
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

def ensure-container [image: string, args: list<string>, name: string, state_dir: path] {
    let running = (podman ps --filter $'name=^($name)$' --format '{{.Names}}' | str trim) == $name
    if $running {
        log debug $'Container ($name) is already running'
        return
    }

    log info $'Starting ($name) in the background'
    mkdir ($state_dir | path join claude)
    touch ($state_dir | path join claude.json)
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

def main [
    --dryrun
    --build
    --shell(-s)
    ...contexts: string
] {
    if $build {
        just -f $'($SCRIPT_DIR)/justfile' build
    }

    let mounts = mount-points (pwd)
    # Host-side storage for the container's Claude Code config/auth. Claude
    # only runs inside the container, so this stays out of the host's ~/.claude.
    let state_dir = $env.XDG_DATA_HOME? | default ($env.HOME | path join .local share) | path join claude-wrapper

    let args = [
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
            $mounts.readwrite
            | each {|v| "--volume=" + $v.src + ":" + $v.dst + ":rw"}
        )
        ...(
            $contexts
            | each {|v| $"--volume=($v):(['/' 'mnt' 'ctx' ($v | path basename)] | path join):ro"}
        )
        $'--volume=($state_dir)/claude:($env.HOME)/.claude'
        $'--volume=($state_dir)/claude.json:($env.HOME)/.claude.json'
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

    if $shell {
        exec podman exec -it $mounts.name bash
    } else {
        exec podman attach $mounts.name
    }
}
