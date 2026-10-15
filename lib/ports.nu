use ns.nu

# A relay is `from container` (the host's port reaches the container's, the
# default) or `from host` (the container's port reaches the host's). Its
# `scope` is where the host side of a `from container` relay listens: `host`
# (127.0.0.1) or `lan` (0.0.0.0, every interface).
export const FROM = [container host]
export const SCOPE = [host lan]

def open-port [file: path, container: string, spec: string, from: string, scope: string] {
    if $from == host and $scope == lan {
        error make {msg: "scope lan only applies to relays from the container: a relay from the host listens on the container's loopback"}
    }

    let port = parse-spec $spec $from | merge {scope: $scope}

    load $file
    | where { |p| (unit $p) != (unit $port) }
    | append $port
    | store $file

    if (running $container) {
        stop $port
        start $port (ns pid $container)
    }
}

export def close [file: path, spec: string, from: string] {
    let port = parse-spec $spec $from

    stop $port

    load $file
    | where { |p| (unit $p) != (unit $port) }
    | store $file
}

export def list [file: path]: nothing -> table {
    load $file
    | each { |p| {spec: (format-spec $p), from: $p.from, scope: $p.scope, active: (active $p)} }
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

def parse-spec [spec: string, from: string]: nothing -> record {
    # A bare port means the same port on both sides
    let spec = $spec | str replace -r '^(\d+)(/tcp|/udp)?$' '$1:$1$2'
    let parsed = $spec | parse --regex '^(?<host>\d+):(?<container>\d+)(?:/(?<proto>tcp|udp))?$'
    if ($parsed | is-empty) {
        error make {msg: $"invalid port spec '($spec)', expected <port> or <host>:<container>[/tcp|/udp]"}
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
        from: $from
    }
}

def format-spec [port: record]: nothing -> string {
    $"($port.host):($port.container)/($port.proto)"
}

def load [file: path]: nothing -> list {
    if ($file | path exists) { open --raw $file | from nuon | default [] | each { upgrade } } else { [] }
}

# Files written before `from` and `scope` existed have `from_host: bool`
# instead; the next `store` rewrites them in the current shape
def upgrade []: record -> record {
    let port = $in
    let port = if "from_host" in $port {
        $port | reject from_host | insert from (if $port.from_host { "host" } else { "container" })
    } else {
        $port
    }
    $port | default host scope
}

def store [file: path] {
    let list = $in
    mkdir ($file | path dirname)
    $list | to nuon | save --force $file
}

# The unit is named after the spec and direction only, so closing a relay
# does not need its scope
def unit [port: record]: nothing -> string {
    let dir = if $port.from == host { "out" } else { "in" }
    $"claude-port-($dir)-($port.proto)-($port.host)-($port.container)"
}

def relay-args [port: record, pid: int, bind: string]: nothing -> list<string> {
    if $port.from == host {
        [relay $"($pid)" outbound $port.proto $"($port.container)" $"($port.host)"]
    } else {
        [relay $"($pid)" inbound $port.proto $"($port.host)" $"($port.container)" $bind]
    }
}

# Where the listening side of the relay binds: the host side of an inbound
# relay is on every interface with scope lan, everything else on loopback
def bind-address [port: record]: nothing -> string {
    if $port.scope == lan { "0.0.0.0" } else { "127.0.0.1" }
}

# The description names the relay, its bind address and the container PID it
# was started for, which `relay-pid` reads back
def description [port: record, pid: int, bind: string]: nothing -> string {
    $"claude port relay (format-spec $port) on ($bind) pid ($pid)"
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
    let bind = bind-address $port
    let result = ^systemd-run --user --collect --quiet $"--unit=(unit $port)" $"--description=(description $port $pid $bind)" ...(ns command ...(relay-args $port $pid $bind)) | complete
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
