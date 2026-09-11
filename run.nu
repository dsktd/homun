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
        $docker = $docker | merge {
            name: ($gitdir | path basename)
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

def start_claude [image: string, ...$args: string] {
    mkdir ($env.HOME)/.claude
    touch ($env.HOME)/.claude.json
    exec podman run --interactive --tty --rm ...$args $image sh -c "claude --continue || claude"
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

    let args = [
        --name=($mounts.name)
        --env
        PS1=($mounts.PS1)
        --env
        ENABLE_LSP_TOOL=1
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
        $'--volume=($env.HOME)/.claude:/home/.claude'
        $'--volume=($env.HOME)/.claude.json:/home/.claude.json'
        --workdir=($mounts.workdir)
        --hostname=($mounts.name)
    ]

    let running = $mounts.name == (podman ps --filter $'name=^($mounts.name)$' --format '{{.Names}}' | str trim)
    if $shell {
        if not $running {
            log error "Cannot open shell without a Claude session open first"
            exit 1
        }
        exec podman exec -it ($mounts.name) bash
    }

    if $running {
        log info $'A session is already running for ($mounts.name); reattaching'
        if $dryrun { return }
        podman exec ($mounts.name) kill -WINCH 1 | ignore
        exec podman attach ($mounts.name)
    }

    print $args
    if $dryrun { return }
    start_claude 'claude' ...$args
}
