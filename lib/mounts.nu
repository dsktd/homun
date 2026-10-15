use ns.nu

export const MODES = [ro rw]

export def add [file: path, container: string, path: path, mode: string] {
    let path = normalize $path

    if not ($path | path exists) {
        error make {msg: $"($path) does not exist"}
    }

    let entries = load $file
    let saved = $path in $entries.path
    let entry = {path: $path, mode: $mode}

    let pid = live-pid $container
    let live = $pid != null and $path in (ns mounted $container)

    if $live and not $saved {
        error make {msg: $"($path) is a container mount not managed by ($file)"}
    }

    save-entries $file ($entries | where path != $path | append $entry)

    if $pid != null {
        if $live { ns invoke unmount ($pid | into string) $path }
        mount-entry $pid $entry
    }
}

export def remove [file: path, container: string, path: path] {
    let path = normalize $path
    let entries = load $file

    if $path not-in $entries.path {
        error make {msg: $"($path) is not in ($file)"}
    }

    let pid = live-pid $container

    if $pid != null and $path in (ns mounted $container) {
        ns invoke unmount ($pid | into string) $path
    }

    save-entries $file ($entries | where path != $path)
}

export def list [file: path, container: string]: nothing -> table {
    let live = ns mounted $container

    load $file
    | each {|entry| $entry | insert live ($entry.path in $live) }
}

export def apply [file: path, container: string] {
    let pid = ns pid $container
    let live = ns mounted $container

    load $file
    | where path not-in $live
    | each {|entry| mount-entry $pid $entry }
    | ignore
}

def load [file: path]: nothing -> list {
    if ($file | path exists) { open $file | default [] } else { [] }
}

def save-entries [file: path, entries: list] {
    mkdir ($file | path dirname)
    $entries | to nuon --indent 2 | save --force $file
}

def live-pid [container: string]: nothing -> any {
    try { ns pid $container } catch { null }
}

def normalize [path: path]: nothing -> string {
    $path | path expand --no-symlink
}

def mount-entry [pid: int, entry: record] {
    let flags = if $entry.mode == "ro" { [--ro] } else { [] }
    ns invoke mount ($pid | into string) $entry.path $entry.path ...$flags
}
