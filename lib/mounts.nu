use ns.nu
use homuncfg.nu

export const MODES = [ro rw]

export def --env add [container: string, path: path, mode: string] {
    let path = normalize $path

    if not ($path | path exists) {
        error make {msg: $"($path) does not exist"}
    }

    let entries = load
    let saved = $path in $entries.path
    let entry = {path: $path, mode: $mode}

    let pid = live-pid $container
    let live = $pid != null and $path in (ns mounted $container)

    if $live and not $saved {
        error make {msg: $"($path) is a container mount not managed by homun.toml"}
    }

    save-entries ($entries | where path != $path | append $entry)

    if $pid != null {
        if $live { ns invoke unmount ($pid | into string) $path }
        mount-entry $pid $entry
    }
}

export def --env remove [container: string, path: path] {
    let path = normalize $path
    let entries = load

    if $path not-in $entries.path {
        error make {msg: $"($path) is not in homun.toml"}
    }

    let pid = live-pid $container

    if $pid != null and $path in (ns mounted $container) {
        ns invoke unmount ($pid | into string) $path
    }

    save-entries ($entries | where path != $path)
}

export def list [container: string]: nothing -> table {
    let live = ns mounted $container

    load
    | each {|entry| $entry | insert live ($entry.path in $live) }
}

# Forget every saved mount (a new container has none of them mounted)
export def reset [] {
    save-entries []
}

export def --env apply [container: string] {
    let pid = ns pid $container
    let live = ns mounted $container

    load
    | where path not-in $live
    | each {|entry|
        # One stale entry (e.g. a host path since deleted) must not abort the start.
        try { mount-entry $pid $entry } catch {|e| print -e $"mounts: skipping ($entry.path): ($e.msg)" }
    }
    | ignore
}

# Fail before a restart stops the old container, not after: the file must parse and
# every saved mode be valid. A saved path that is gone is not an error; apply skips it.
export def check [] {
    for entry in (load) {
        if ($entry.mode? | default "") not-in $MODES {
            error make {msg: $"homun.toml: entry ($entry | to nuon) has an invalid mode; fix it with `homun mount del`"}
        }
    }
}

def load []: nothing -> list { homuncfg read mount [] }

def save-entries [entries: list] { homuncfg write mount $entries }

def live-pid [container: string]: nothing -> any {
    try { ns pid $container } catch { null }
}

def normalize [path: path]: nothing -> string {
    $path | path expand --no-symlink
}

def --env mount-entry [pid: int, entry: record] {
    let flags = if $entry.mode == "ro" { [--ro] } else { [] }
    ns invoke mount ($pid | into string) $entry.path $entry.path ...$flags
}
