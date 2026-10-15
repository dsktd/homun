use ns.nu

def open-port [file: path, container: string, spec: string, --from-host] {
    let port = parse-spec $spec $from_host

    load $file
    | where { |p| (unit $p) != (unit $port) }
    | append $port
    | store $file

    if (running $container) {
        stop $port
        start $port (ns pid $container)
    }
}

export def close [file: path, spec: string, --from-host] {
    let port = parse-spec $spec $from_host

    stop $port

    load $file
    | where { |p| (unit $p) != (unit $port) }
    | store $file
}

export def list [file: path]: nothing -> table {
    load $file
    | each { |p| {spec: (format-spec $p), from_host: $p.from_host, active: (active $p)} }
}

export def apply [file: path, container: string] {
    let pid = ns pid $container

    for port in (load $file) {
        if (active $port) and (relay-pid $port) == $pid {
            continue
        }

        stop $port
        start $port $pid
    }
}

def parse-spec [spec: string, from_host: bool]: nothing -> record {
    let parsed = $spec | parse --regex '^(?<host>\d+):(?<container>\d+)(?:/(?<proto>tcp|udp))?$'
    if ($parsed | is-empty) {
        error make {msg: $"invalid port spec '($spec)', expected <host>:<container>[/tcp|/udp]"}
    }

    let p = $parsed | first
    let host = $p.host | into int
    let container = $p.container | into int

    for n in [$host $container] {
        if $n < 1 or $n > 65535 {
            error make {msg: $"port ($n) out of range in '($spec)'"}
        }
    }

    {
        host: $host
        container: $container
        proto: (if ($p.proto | is-empty) { "tcp" } else { $p.proto })
        from_host: $from_host
    }
}

def format-spec [port: record]: nothing -> string {
    $"($port.host):($port.container)/($port.proto)"
}

def load [file: path]: nothing -> list {
    if ($file | path exists) { open --raw $file | from nuon | default [] } else { [] }
}

def store [file: path] {
    let list = $in
    mkdir ($file | path dirname)
    $list | to nuon | save --force $file
}

def unit [port: record]: nothing -> string {
    let dir = if $port.from_host { "out" } else { "in" }
    $"claude-port-($dir)-($port.proto)-($port.host)-($port.container)"
}

def relay-args [port: record, pid: int]: nothing -> list<string> {
    if $port.from_host {
        [relay $"($pid)" outbound $port.proto $"($port.container)" $"($port.host)"]
    } else {
        [relay $"($pid)" inbound $port.proto $"($port.host)" $"($port.container)"]
    }
}

def description [port: record, pid: int]: nothing -> string {
    $"claude port relay (format-spec $port) pid ($pid)"
}

def relay-pid [port: record]: nothing -> any {
    let shown = ^systemctl --user show --property=Description --value $"(unit $port).service" | complete
    let found = $shown.stdout | str trim | parse --regex " pid (?<pid>\\d+)$"

    if ($found | is-empty) { null } else { $found.0.pid | into int }
}

def running [container: string]: nothing -> bool {
    try { ns pid $container; true } catch { false }
}

def active [port: record]: nothing -> bool {
    (^systemctl --user is-active --quiet $"(unit $port).service" | complete).exit_code == 0
}

def start [port: record, pid: int] {
    let result = ^systemd-run --user --collect --quiet $"--unit=(unit $port)" $"--description=(description $port $pid)" ...(ns command ...(relay-args $port $pid)) | complete
    if $result.exit_code != 0 {
        error make {msg: ($result.stderr | str trim)}
    }
}

def stop [port: record] {
    ^systemctl --user stop $"(unit $port).service" | complete | ignore
    ^systemctl --user reset-failed $"(unit $port).service" | complete | ignore
}

# HACK: an exported `def open` would shadow the builtin `open` used by `load` in this module
export alias open = open-port
