# fixes: a6a38df container restart, roll: recreate the manager alone first, gated, before the mechanic
# With a mechanic, `container restart` brings the manager back before it stops the mechanic, so
# an agent is always up to repair a manager that does not come back (the fake manager here never
# passes the gate, so the mechanic must not be stopped before it is started).
def main [root: path] {
    let root = $root | path expand
    let dir = mktemp -d
    let bin = $dir | path join bin
    let state = $dir | path join state
    let home = $dir | path join home
    mkdir $bin $state ($dir | path join runtime) ($home | path join .config claude)
    for n in [podman pgrep systemd-run systemctl git xdg-dbus-proxy claude-ns claude-update claude emacsclient] {
        ln -s ($root | path join tests fake) ($bin | path join $n)
    }
    touch ($dir | path join runtime wayland-0) ($state | path join running) ($state | path join exists)
    {roles: [mechanic]} | to json | save ($home | path join .config claude config.json)
    "running healthy 0" | save ($state | path join c-claude-mechanic)
    let log = $dir | path join calls.log
    with-env {
        HOME: $home, XDG_CONFIG_HOME: ($home | path join .config), XDG_DATA_HOME: ($dir | path join data)
        XDG_CACHE_HOME: ($dir | path join cache), XDG_RUNTIME_DIR: ($dir | path join runtime)
        WAYLAND_DISPLAY: wayland-0, HOMUN_CONTAINERENV: ($dir | path join no), HOMUN_FLAKE: "1"
        CLAUDE_PROXY_ADMIN: "127.0.0.1:2919", DBUS_SESSION_BUS_ADDRESS: "unix:path=/nonexistent/bus"
        PATH: ($env.PATH | prepend $bin), FAKE_LOG: $log, FAKE_STATE: $state, FAKE_PID: ($nu.pid | into string)
        HOMUN_GATE_SECONDS: "5", HOMUN_GATE_POLL: "0"
    } {
        ^timeout 15 nu ($root | path join run.nu) container restart force | complete | ignore
    }
    let calls = open --raw $log | lines | enumerate
    let up = $calls | where {|c| $c.item =~ '^podman (run|start) .*claude-manager' } | get -o 0.index
    let down = $calls | where {|c| $c.item =~ '^podman stop .*claude-mechanic' } | get -o 0.index
    rm -rf $dir
    if $up == null { error make {msg: "the manager was not started"} }
    # The fake manager never passes the gate, so the fixed code leaves the mechanic running
    if $down != null and $down < $up { error make {msg: "the mechanic was stopped before the manager was back"} }
}
