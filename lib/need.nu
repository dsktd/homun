use std/log
use hostcfg.nu

const ROOT = path self | path dirname | path dirname

# Make sure each named tool is on PATH, before the first use of it. A bare
# ./run.nu (or the `homun` symlink) seldom has them all: take them from the flake's
# `deps` package, built into a GC-rooted link under $XDG_CACHE_HOME/homun
# and built only when it does not exist yet: an existing one is used as it is, never
# rebuilt as a side effect of running a command (`refresh` does that, from
# bin/claude-update's build), put its bin on PATH and carry on in this
# process (the checkout's own code, so live mounts like container/ keep pointing
# at the checkout). Costs nothing when the tools are present, and is skipped in
# a container, where the host-only guard gives the better error, and under
# HOMUN_FLAKE (set by the `nix run` wrapper). `path:` so an uncommitted
# checkout works. Every caller up the chain must be `def --env` for the PATH
# change to reach the external call.
def deps-dir [] { $env.XDG_CACHE_HOME? | default ($env.HOME | path join .cache) | path join homun }

# Rebuild the deps link from the flake as it is now (the explicit update path only)
export def refresh [] {
    let dir = deps-dir
    mkdir $dir
    nix build --out-link ($dir | path join deps) $"path:($ROOT)#deps"
}

export def --env main [...tools: string] {
    if ($env.HOMUN_FLAKE? | default "") != "" { return }
    if (hostcfg in-container) { return }
    if ($tools | all {|t| which $t | is-not-empty }) { return }
    if (which nix | is-empty) {
        log error $"Missing from PATH: ($tools | where {|t| which $t | is-empty } | str join ', '), and no `nix` to fetch them with; install nix or those tools \(see ($ROOT)/flake.nix)"
        exit 1
    }
    let link = deps-dir | path join deps
    if not ($link | path exists) {
        log info $"Missing from PATH: ($tools | where {|t| which $t | is-empty } | str join ', '); building them through the flake"
        refresh
    }
    $env.PATH = $env.PATH | prepend ($link | path join bin)
    let still = $tools | where {|t| which $t | is-empty }
    if ($still | is-not-empty) {
        error make {msg: $"($still | str join ', ') missing from PATH and from the flake's deps package"}
    }
}
