export def pid [container: string]: nothing -> int {
    let result = ^podman inspect --format '{{.State.Pid}}' $container | complete

    if $result.exit_code != 0 {
        error make {msg: ($result.stderr | str trim | default --empty $"container ($container) does not exist")}
    }

    let pid = $result.stdout | str trim | into int

    if $pid == 0 {
        error make {msg: $"container ($container) is not running"}
    }

    $pid
}

export def command [...args: string]: nothing -> list<string> {
    # Absolute path: relays run as systemd units, whose PATH lacks the flake's claude-ns
    let ns = which claude-ns | get -o 0.path | default claude-ns
    [podman unshare $ns ...$args]
}

export def invoke [...args: string] {
    # Normally unreachable: run.nu bootstraps through the flake when claude-ns is missing
    if (which claude-ns | is-empty) {
        error make {msg: "claude-ns is not on PATH: run the launcher with `nix run <checkout>`, or `./run.nu` with `nix` installed"}
    }
    let argv = command ...$args
    let result = ^$argv.0 ...($argv | skip 1) | complete

    if $result.exit_code != 0 {
        error make {msg: ($result.stderr | str trim | default --empty $"claude-ns ($args | str join ' ') failed")}
    }
}

export def mounted [container: string]: nothing -> list<string> {
    let pid = try { pid $container } catch { return [] }
    let info = try { open --raw $"/proc/($pid)/mountinfo" } catch { return [] }

    $info
    | lines
    | each {|line| $line | split row ' ' | get 4 | unescape }
}

def unescape []: string -> string {
    $in
    | str replace --all '\040' ' '
    | str replace --all '\011' "\t"
    | str replace --all '\012' "\n"
    | str replace --all '\134' '\'
}
