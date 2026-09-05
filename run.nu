#!/usr/bin/env nu

use std/log

const SCRIPT_DIR: string = path self | path expand | path dirname
const DRY_RUN: bool = true

def mount-points [dir: path]: nothing -> record {
    let workspace_path = ($env.HOME | path join "workspaces")
    let relpath = try { $dir | path expand | (path relative-to $workspace_path) } catch { "" }
    let is_git = (git rev-parse --show-toplevel | ignore -e | into bool --relaxed)
    let is_worktree = ($is_git and ((git rev-parse --show-toplevel | path join ".git" | path type) == file))
    let is_treebundel = ($is_worktree and ($relpath | path split | length) >= 2)

    # A managed treebundel project
    if $is_treebundel {
        log info $'Opening as treebundel project'

        let workspace = ($relpath | path split | get 0)
        let project = ($relpath | path split | get 1)
        return {
            # name: $'($workspace)/($project)'
            name: $'($workspace)-($project)'
            PS1: $'🪾(ansi blue_bold)($workspace)(ansi reset)/(ansi green_bold)($project)(ansi reset)$ '
            readonly: [[src dst];
                [($env.HOME + "/workspaces/.bare") ($env.HOME + "/workspaces/.bare")]
            ]
            readwrite: [[src dst];
                [(pwd) (pwd)]
            ]
            workdir: (pwd)
        }
    }

    # An unknown git project
    if $is_git {
        log info $'Opening as normal git project'
        let gitdir = (git rev-parse --show-toplevel)
        return {
            name: ($gitdir | path basename)
            PS1: $'(ansi white_dimmed)\h(ansi reset)$ '
            readonly: null
            readwrite: [[src dst];
                [(pwd) (pwd)]
            ]
            workdir: (pwd)
        }

    }

    log info $'Opening as a directory'
    {
        name: (pwd | path basename)
        PS1: $'(ansi white_bold)\h(ansi reset)$ '
        readonly: null
        readwrite: [[src dst];
            [(pwd) (pwd)]
        ]
        workdir: (pwd)
    }
}

def start_claude [cmd: string ...$args: string] {
    mkdir ($env.HOME)/.claude
    touch ($env.HOME)/.claude.json
    exec podman run --interactive --tty --rm ...$args $cmd
}

def main [...contexts: string; --dryrun --build --shell(-s)] {
    if $build {
        just -f $'($SCRIPT_DIR)/justfile' build
    }

    let mounts = (mount-points (pwd))

    let args = [
        --name=($mounts.name)
        --env PS1=($mounts.PS1)
        --env ENABLE_LS_TOOL=1
        ...($mounts.readonly | each {|v| "--volume=" + $v.src + ":" + $v.dst + ":ro"})
        ...($mounts.readwrite | each {|v| "--volume=" + $v.src + ":" + $v.dst + ":rw"})
        ...($contexts | each {|v| $"--volume=($v):(['/' 'mnt' 'ctx' ($v | path basename)] | path join):ro"})
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

    # ^p ^q to detach
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
