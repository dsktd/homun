#!/usr/bin/env nu
# The test suite (`just test`): lints every script, then drives run.nu,
# container/start.sh, container/request-update.sh and bin/claude-attach
# against fake podman/systemd-run/systemctl/git/claude in a throwaway HOME and
# asserts on what they tried to run. Nothing real is touched.

use std/assert

const TESTS_DIR: string = path self | path expand | path dirname
const REPO = $TESTS_DIR | path dirname
const RUN = $REPO | path join run.nu
const SERVICES = $REPO | path join container services.sh
const IMPORT = $REPO | path join container services usage-db import.nu
const NAME = "claude-manager"
const FAKES = [podman systemd-run systemctl git xdg-dbus-proxy claude-ns claude-update claude emacsclient]
const CLAUDE_EMACS = $REPO | path join bin claude-emacs
const EMACS_CONF = $REPO | path join container emacs
# What a bare ./run.nu also wants on PATH before it re-runs itself through the flake
const BOOTSTRAP_FAKES = [zellij just nix]

def main [] {
    let results = [
        (test-lint)
        (test-dryrun)
        (test-detach)
        (test-mounts)
        (test-ports)
        (test-clone)
        (test-host-only)
        (test-bootstrap)
        (test-zellij-config)
        (test-start)
        (test-container)
        (test-attach)
        (test-services)
        (test-usage-db)
        (test-transcripts)
        (test-proxy)
        (test-emacs-cli)
        (test-emacs-frame)
        (test-emacs-init)
    ] | flatten

    print ""
    let failed = $results | where status == fail
    let skipped = $results | where status == skip
    print $"($results | length) checks: (($results | length) - ($failed | length) - ($skipped | length)) passed, ($failed | length) failed, ($skipped | length) skipped"
    if ($failed | is-not-empty) { exit 1 }
}

# --- harness -----------------------------------------------------------------

# Run one named check; the closure passes by returning, fails by erroring.
# Helpers here must not shadow builtins (`skip`, `run`): nu-check parses the
# linted files in this scope.
def check [name: string, body: closure]: nothing -> record {
    let result = try { do $body; {status: pass, msg: ""} } catch {|err| {status: fail, msg: $err.msg} }
    if $result.status == pass {
        print $"ok   ($name)"
    } else {
        print $"FAIL ($name)"
        print $"     ($result.msg)"
    }
    $result | insert name $name
}

def skipped [name: string, why: string]: nothing -> record {
    print $"skip ($name) \(($why))"
    {status: skip, msg: $why, name: $name}
}

# A throwaway HOME/XDG tree with the fakes on PATH and an empty call log.
# CLAUDE_WRAPPER_CONTAINERENV points run.nu's container check at a missing file
# so host-only subcommands run even when the suite itself is in a container, and
# CLAUDE_WRAPPER_FLAKE keeps run.nu from re-running itself through the flake.
def sandbox []: nothing -> record {
    let dir = mktemp -d --suffix -claude-wrapper-test
    let bin = $dir | path join bin
    let state = $dir | path join state
    mkdir $bin $state ($dir | path join runtime)
    for name in $FAKES { ln -s ($TESTS_DIR | path join fake) ($bin | path join $name) }
    # A Wayland display, for the emacs service's socket mount
    touch ($dir | path join runtime wayland-0)

    {
        dir: $dir
        home: ($dir | path join home)
        env: {
            HOME: ($dir | path join home)
            XDG_CONFIG_HOME: ($dir | path join xdg-config)
            XDG_DATA_HOME: ($dir | path join xdg-data)
            XDG_CACHE_HOME: ($dir | path join xdg-cache)
            XDG_RUNTIME_DIR: ($dir | path join runtime)
            WAYLAND_DISPLAY: wayland-0
            CLAUDE_WRAPPER_CONTAINERENV: ($dir | path join not-a-container)
            CLAUDE_WRAPPER_FLAKE: "1"
            CLAUDE_PROXY_ADMIN: "127.0.0.1:2919" # never the real proxy's admin API
            DBUS_SESSION_BUS_ADDRESS: "unix:path=/nonexistent/bus"
            PATH: ($env.PATH | prepend $bin)
            FAKE_LOG: ($dir | path join calls.log)
            FAKE_STATE: $state
            FAKE_PID: ($nu.pid | into string)
        }
    }
}

# Run the body with a fresh sandbox, removing it afterwards whatever happens
def with-sandbox [body: closure]: nothing -> list<record> {
    let sb = sandbox
    let results = try { do $body $sb } catch {|err| rm -rf $sb.dir; $err.raw }
    rm -rf $sb.dir
    $results
}

# Run run.nu in the sandbox; returns {exit_code, stdout, stderr}
def launch [sb: record, ...args: string]: nothing -> record {
    with-env $sb.env { ^nu $RUN ...$args | complete }
}

def calls [sb: record]: nothing -> list<string> {
    if ($sb.env.FAKE_LOG | path exists) { open --raw $sb.env.FAKE_LOG | lines } else { [] }
}

def calls-starting-with [sb: record, prefix: string]: nothing -> list<string> {
    calls $sb | where ($it | str starts-with $prefix)
}

def assert-ok [result: record] {
    assert equal $result.exit_code 0 $"run.nu failed: ($result.stderr | str trim)"
}

def assert-fails [result: record] {
    assert ($result.exit_code != 0) $"run.nu succeeded unexpectedly:\n($result.stdout)"
}

# An exact call was logged (for contract strings: unit names, claude-ns and git argv)
def assert-called [sb: record, call: string] {
    let logged = calls $sb
    assert ($call in $logged) $"expected call missing: ($call)\n     calls:\n       ($logged | str join "\n       ")"
}

# Some call of the tool contains every required token (in any order) and ends with tail
def assert-called-with [sb: record, tool: string, required: list<string>, --tail: list<string> = []] {
    let end = $tail | prepend "" | str join " "
    let hits = calls-starting-with $sb $"($tool) "
    let matched = $hits | where {|c| ($required | all {|t| $t in $c }) and ($c | str ends-with $end) }
    assert ($matched | is-not-empty) $"no ($tool) call with ($required) ending in '($end)':\n       ($hits | str join "\n       ")"
}

def assert-not-called [sb: record, prefix: string] {
    let hits = calls-starting-with $sb $prefix
    assert ($hits | is-empty) $"unexpected calls:\n       ($hits | str join "\n       ")"
}

# The systemd unit of a port relay: `in` is host -> container, `out` the reverse
def port-unit [dir: string, proto: string, host: int, container: int]: nothing -> string {
    $"claude-port-($dir)-($proto)-($host)-($container)"
}

# The systemd-run invocation that starts a port relay
def relay-call [sb: record, dir: string, proto: string, host: int, container: int, --lan]: nothing -> string {
    let pid = $sb.env.FAKE_PID
    let unit = port-unit $dir $proto $host $container
    let bind = if $lan { "0.0.0.0" } else { "127.0.0.1" }
    let relay = if $dir == in { $"inbound ($proto) ($host) ($container) ($bind)" } else { $"outbound ($proto) ($container) ($host)" }
    $"systemd-run --user --collect --quiet --unit=($unit) --description=claude port relay ($host):($container)/($proto) on ($bind) pid ($pid) podman unshare claude-ns relay ($pid) ($relay)"
}

def shebang [file: path]: nothing -> string {
    open --raw $file | lines | first | default ""
}

# --- 1. lint -----------------------------------------------------------------

def test-lint []: nothing -> list<record> {
    let scripts = [run.nu] | append (ls ($REPO | path join bin) | get name | path relative-to $REPO)
    | append [container/entrypoint.sh container/start.sh container/request-update.sh container/statusline.sh container/usage-hook.sh container/services.sh container/services/usage-db/run container/services/usage-db/import.nu container/services/proxy/run container/services/status/run container/services/scheduler/run container/services/emacs/run tests/fake tests/run.nu]
    let nu_scripts = $scripts | where {|f| (shebang ($REPO | path join $f)) =~ '\bnu$' }
    let sh_scripts = $scripts | where {|f| (shebang ($REPO | path join $f)) =~ '\bsh$' }
    assert equal (($nu_scripts | length) + ($sh_scripts | length)) ($scripts | length) $"scripts without a nu/sh shebang: ($scripts | where $it not-in $nu_scripts and $it not-in $sh_scripts)"
    let modules = ls ($REPO | path join lib) | get name | path relative-to $REPO

    [
        ...($nu_scripts | each {|f| check $"nu-check ($f)" { assert (nu-check ($REPO | path join $f)) } })
        ...($modules | each {|f| check $"nu-check --as-module ($f)" { assert (nu-check --as-module ($REPO | path join $f)) } })
        ...($sh_scripts | each {|f| check $"sh -n ($f)" {
            let r = ^sh -n ($REPO | path join $f) | complete
            assert equal $r.exit_code 0 ($r.stderr | str trim)
        } })
        (if (which python3 | is-empty) { skipped "python3 ast.parse container/services/usage-db/serve.py" "python3 not on PATH" } else {
            check "python3 ast.parse container/services/usage-db/serve.py" {
                # ast.parse rather than py_compile, which writes __pycache__ into the checkout
                let r = ^python3 -I -c "import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])" ($REPO | path join container services usage-db serve.py) | complete
                assert equal $r.exit_code 0 ($r.stderr | str trim)
            }
        })
    ]
}

# --- 2. --dryrun -------------------------------------------------------------

def test-dryrun []: nothing -> list<record> {
    with-sandbox {|sb|
        let home = $sb.home
        let r = launch $sb "--dryrun"
        let out = $r.stdout | lines
        let args = [
            $"--name=($NAME)"
            $"--workdir=($home)/claude"
            $"HOME=($home)"
            $"--volume=($home)/claude:($home)/claude:rw"
            $"--volume=($home)/.local/share/claude/claude:($home)/.claude:rw"
            $"--volume=($home)/.local/share/claude/claude.json:($home)/.claude.json:rw"
            $"--volume=($home)/.local/share/claude/gh:($home)/.config/gh:rw"
            $"--volume=($home)/.local/share/claude/scratch:/tmp/claude-0:rw"
            $"--volume=($home)/.local/share/claude/git:($home)/.config/git:rw"
            $"--volume=($REPO)/container:/opt/claude-wrapper:ro"
            $"--volume=($sb.env.XDG_RUNTIME_DIR)/wayland-0:/run/claude-wayland:rw"
            ...(if ("/etc/localtime" | path exists) { [$"--volume=('/etc/localtime' | path expand):/etc/localtime:ro"] } else { [] })
            "--volume=claude-nix:/nix"
            $"--volume=claude-code:($home)/.local/share/claude"
            "--security-opt=unmask=/proc/*"
        ]

        [
            (check "--dryrun exits 0" { assert-ok $r })
            ...($args | each {|a| check $"--dryrun plans ($a)" { assert ($a in $out) $"not in output:\n($r.stdout)" } })
            (check "--dryrun plans the seed of ~/claude/CLAUDE.md" {
                # the prep table wraps long paths across cell rows
                let prep = $r.stdout | str replace --all --regex '[│\s]' ''
                assert ($"($REPO)/manager/CLAUDE.md" in $prep) $r.stdout
                assert ($"($home)/claude/CLAUDE.md" in $prep) $r.stdout
            })
            (check "--dryrun touches nothing" {
                assert (not ($home | path exists)) "HOME was created"
                assert-not-called $sb "podman"
                assert-not-called $sb "systemd-run"
            })
        ]
    }
}

# --- 3. --detach: start the container with saved mounts and ports ---------------

def test-detach []: nothing -> list<record> {
    with-sandbox {|sb|
        let home = $sb.home
        let config = $home | path join .config claude
        let mounted = $sb.dir | path join shared
        mkdir $config $mounted
        [{path: $mounted, mode: ro}] | to nuon | save ($config | path join mounts.nuon)
        [{host: 8080, container: 3000, proto: tcp, from: container, scope: host} {host: 8443, container: 8443, proto: tcp, from: container, scope: lan}] | to nuon | save ($config | path join ports.nuon)

        let r = launch $sb "--detach"
        let pid = $sb.env.FAKE_PID
        let socket = $sb.env.XDG_RUNTIME_DIR | path join claude-bus

        [
            (check "--detach exits 0" { assert-ok $r })
            (check "--detach creates the state directories" {
                for d in [claude claude/.bare .local/share/claude/claude .local/share/claude/gh .local/share/claude/git .local/share/claude/scratch] {
                    assert equal ($home | path join $d | path type) dir $"missing dir ($d)"
                }
                assert (($home | path join .local share claude claude.json | path type) == file) "claude.json not touched"
                assert (($home | path join .local share claude git config | path type) == file) "git/config not touched"
            })
            (check "--detach seeds ~/claude/CLAUDE.md from manager/CLAUDE.md" {
                assert equal (open --raw ($home | path join claude CLAUDE.md)) (open --raw ($REPO | path join manager CLAUDE.md))
            })
            (check "--detach starts the notify proxy" {
                assert-called-with $sb systemd-run [
                    --user --collect --unit=claude-dbus-proxy
                    $"xdg-dbus-proxy unix:path=/nonexistent/bus ($socket) --filter --talk=org.freedesktop.Notifications"
                ]
            })
            (check "--detach runs podman once with the planned arguments" {
                assert equal (calls-starting-with $sb "podman run " | length) 1
                assert-called-with $sb "podman run" [
                    --detach --interactive --tty
                    $"--name=($NAME)" $"--hostname=($NAME)" $"--workdir=($home)/claude"
                    $"--env HOME=($home)"
                    "--env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/claude-bus"
                    $"--volume=($home)/claude:($home)/claude:rw"
                    $"--volume=($socket):/run/claude-bus:rw"
                    $"--volume=($sb.env.XDG_RUNTIME_DIR)/wayland-0:/run/claude-wayland:rw"
                    "--volume=claude-nix:/nix"
                ] --tail [claude]
            })
            (check "--detach reapplies saved mounts" {
                assert-called $sb $"podman unshare claude-ns mount ($pid) ($mounted) ($mounted) --ro"
            })
            (check "--detach reapplies saved ports" {
                assert-called $sb (relay-call $sb in tcp 8080 3000)
            })
            (check "--detach reapplies a scope lan relay on 0.0.0.0" {
                assert-called $sb (relay-call $sb in tcp 8443 8443 --lan)
            })
            (check "--detach does nothing when the container is already running" {
                assert-ok (launch $sb "--detach")
                assert equal (calls-starting-with $sb "podman run " | length) 1
            })
            (check "--detach keeps the container (no --rm) and replaces a stopped one" {
                assert-not-called $sb "podman run --detach --interactive --tty --rm"
                rm ($sb.env.FAKE_STATE | path join running)
                assert-ok (launch $sb "--detach")
                assert-called $sb $"podman rm --ignore ($NAME)"
                assert equal (calls-starting-with $sb "podman run " | length) 2
            })
            (check "--restart-container stops and removes the running container first" {
                assert-ok (launch $sb "--restart-container" "--detach")
                assert-called $sb $"podman stop ($NAME)"
                assert equal (calls-starting-with $sb "podman run " | length) 3
                let order = calls $sb | where ($it | str starts-with "podman stop ") or ($it | str starts-with "podman rm ") or ($it | str starts-with "podman run ") | last 4 | each { split words | first 2 | str join " " }
                assert equal $order ["podman stop" "podman rm" "podman rm" "podman run"] "expected stop, rm, rm (ensure-container's), run"
            })
        ]
    } | append (with-sandbox {|sb|
        # A ports.nuon from before `from`/`scope`: `from_host: bool` and no scope
        let config = $sb.home | path join .config claude
        mkdir $config
        [{host: 8080, container: 3000, proto: tcp, from_host: false} {host: 5432, container: 5433, proto: udp, from_host: true}] | to nuon | save ($config | path join ports.nuon)

        let r = launch $sb "--detach"

        [
            (check "--detach reapplies ports saved in the old from_host shape" {
                assert-ok $r
                assert-called $sb (relay-call $sb in tcp 8080 3000)
                assert-called $sb (relay-call $sb out udp 5432 5433)
            })
        ]
    })
}

# --- 4. mount / unmount / mounts ----------------------------------------------

def test-mounts []: nothing -> list<record> {
    with-sandbox {|sb|
        let file = $sb.home | path join .config claude mounts.nuon
        let pid = $sb.env.FAKE_PID
        let ro = $sb.dir | path join ro
        let rw = $sb.dir | path join rw
        mkdir $ro $rw
        touch ($sb.env.FAKE_STATE | path join running)

        [
            (check "mount <path> binds read-only and saves it" {
                assert-ok (launch $sb mount $ro)
                assert-called $sb $"podman unshare claude-ns mount ($pid) ($ro) ($ro) --ro"
                assert equal (open $file) [{path: $ro, mode: ro}]
            })
            (check "mount <path> rw binds read-write" {
                assert-ok (launch $sb mount $rw rw)
                assert-called $sb $"podman unshare claude-ns mount ($pid) ($rw) ($rw)"
                assert equal (open $file) [{path: $ro, mode: ro} {path: $rw, mode: rw}]
            })
            (check "mount rejects a mode other than ro or rw" {
                for mode in ["--rw" wr "rw extra"] {
                    assert-fails (launch $sb mount $rw ...($mode | split row ' '))
                }
                let r = launch $sb mount $rw wr
                assert ("ro|rw" in $r.stderr) $r.stderr
                assert equal (calls-starting-with $sb $"podman unshare claude-ns mount ($pid) ($rw)" | length) 1
            })
            (check "mount refuses a missing path" {
                let r = launch $sb mount ($sb.dir | path join nope)
                assert-fails $r
                assert ("does not exist" in $r.stderr) $r.stderr
            })
            (check "mounts lists the saved entries" {
                let r = launch $sb mounts
                assert-ok $r
                assert ($ro in $r.stdout) $r.stdout
                assert ($rw in $r.stdout) $r.stdout
            })
            (check "unmount forgets the entry" {
                assert-ok (launch $sb unmount $ro)
                assert equal (open $file) [{path: $rw, mode: rw}]
            })
            (check "unmount refuses an unknown path" {
                assert-fails (launch $sb unmount $ro)
            })
            (check "mount works without a running container" {
                rm ($sb.env.FAKE_STATE | path join running)
                let later = $sb.dir | path join later
                mkdir $later
                assert-ok (launch $sb mount $later)
                assert-not-called $sb $"podman unshare claude-ns mount ($pid) ($later)"
                assert equal (open $file) [{path: $rw, mode: rw} {path: $later, mode: ro}]
            })
        ]
    }
}

# --- 5. port open / close / ports ---------------------------------------------

def test-ports []: nothing -> list<record> {
    with-sandbox {|sb|
        let file = $sb.home | path join .config claude ports.nuon
        touch ($sb.env.FAKE_STATE | path join running)

        [
            (check "port open <host>:<container> relays inbound tcp on loopback" {
                assert-ok (launch $sb port open 8080:3000)
                assert-called $sb $"systemctl --user stop (port-unit in tcp 8080 3000).service"
                assert-called $sb (relay-call $sb in tcp 8080 3000)
                assert equal (open $file) [{host: 8080, container: 3000, proto: tcp, from: container, scope: host}]
            })
            (check "port open ... from host relays outbound" {
                assert-ok (launch $sb port open 5432:5433/udp from host)
                assert-called $sb (relay-call $sb out udp 5432 5433)
                assert equal (open $file) [
                    {host: 8080, container: 3000, proto: tcp, from: container, scope: host}
                    {host: 5432, container: 5433, proto: udp, from: host, scope: host}
                ]
            })
            (check "port open replaces an existing relay instead of duplicating it" {
                assert-ok (launch $sb port open 8080:3000/tcp)
                assert equal (open $file | length) 2
            })
            (check "port open ... scope lan binds the host side to every interface" {
                assert-ok (launch $sb port open 8080:3000 scope lan)
                assert-called $sb (relay-call $sb in tcp 8080 3000 --lan)
                assert equal (open $file | where host == 8080) [{host: 8080, container: 3000, proto: tcp, from: container, scope: lan}]
                assert-ok (launch $sb port open 8082/udp scope lan)
                assert-called $sb (relay-call $sb in udp 8082 8082 --lan)
            })
            (check "ports shows the scope" {
                let r = launch $sb ports
                assert-ok $r
                let lan = $r.stdout | lines | where { |l| "8080:3000/tcp" in $l }
                assert (($lan | length) == 1 and "lan" in $lan.0) $r.stdout
            })
            (check "port open without scope lan puts the relay back on loopback" {
                assert-ok (launch $sb port open 8080:3000)
                assert equal (open $file | where host == 8080) [{host: 8080, container: 3000, proto: tcp, from: container, scope: host}]
                assert equal (calls-starting-with $sb (relay-call $sb in tcp 8080 3000) | length) 3
            })
            (check "port open rejects scope lan from host" {
                assert-fails (launch $sb port open 5432:5433/udp from host scope lan)
                assert-fails (launch $sb port open 5432:5433/udp scope lan from host)
            })
            (check "port open rejects unknown options and values" {
                let r = launch $sb port open 8083 bogus 1
                assert-fails $r
                assert ("[from container|host] [scope host|lan]" in $r.stderr) $r.stderr
                for options in [[--lan] [scope] [scope wan] [from nowhere] [8084] [scope lan extra]] {
                    assert-fails (launch $sb port open 8083 ...$options)
                }
                assert-not-called $sb (relay-call $sb in tcp 8083 8083)
            })
            (check "port open rejects bad specs" {
                for spec in ["a:b" "0:80" "80:70000" "1:2/sctp" "8080:"] {
                    assert-fails (launch $sb port open $spec)
                }
                assert equal (open $file | length) 3
            })
            (check "port open takes a bare port as host:container" {
                assert-ok (launch $sb port open 8081)
                assert-called $sb (relay-call $sb in tcp 8081 8081)
                assert-ok (launch $sb port close 8081)
            })
            (check "ports lists the relays" {
                let r = launch $sb ports
                assert-ok $r
                assert ("8080:3000/tcp" in $r.stdout) $r.stdout
                assert ("5432:5433/udp" in $r.stdout) $r.stdout
            })
            (check "port close stops the unit and forgets it" {
                assert-ok (launch $sb port close 5432:5433/udp from host)
                assert-called $sb $"systemctl --user stop (port-unit out udp 5432 5433).service"
                assert-called $sb $"systemctl --user reset-failed (port-unit out udp 5432 5433).service"
                assert-ok (launch $sb port close 8082/udp)
                assert equal (open $file) [{host: 8080, container: 3000, proto: tcp, from: container, scope: host}]
            })
            (check "port close rejects unknown options" {
                assert-fails (launch $sb port close 8080:3000 scope lan)
                assert equal (open $file | length) 1
            })
            (check "port open only saves when the container is not running" {
                rm ($sb.env.FAKE_STATE | path join running)
                assert-ok (launch $sb port open 9000:9000)
                assert-not-called $sb (relay-call $sb in tcp 9000 9000)
                assert equal (open $file | length) 2
            })
        ]
    } | append (with-sandbox {|sb|
        # A ports.nuon from before `from`/`scope`: `from_host: bool` and no scope
        let file = $sb.home | path join .config claude ports.nuon
        mkdir ($file | path dirname)
        [{host: 8080, container: 3000, proto: tcp, from_host: false} {host: 5432, container: 5433, proto: udp, from_host: true}] | to nuon | save $file
        touch ($sb.env.FAKE_STATE | path join running)

        [
            (check "ports reads the old from_host shape" {
                let r = launch $sb ports
                assert-ok $r
                assert ("8080:3000/tcp" in $r.stdout) $r.stdout
                assert ("5432:5433/udp" in $r.stdout) $r.stdout
            })
            (check "port close works on the old shape and rewrites the file" {
                assert-ok (launch $sb port close 5432:5433/udp from host)
                assert-called $sb $"systemctl --user stop (port-unit out udp 5432 5433).service"
                assert equal (open $file) [{host: 8080, container: 3000, proto: tcp, from: container, scope: host}]
            })
        ]
    })
}

# --- 6. clone ----------------------------------------------------------------

def test-clone []: nothing -> list<record> {
    with-sandbox {|sb|
        let bare = $sb.home | path join claude .bare

        [
            (check "clone <url> bare-clones into ~/claude/.bare/<basename>.git" {
                assert-ok (launch $sb clone https://example.com/org/thing.git)
                let repo = $bare | path join thing.git
                assert-called $sb $"git clone --bare -- https://example.com/org/thing.git ($repo)"
                assert-called $sb $"git -C ($repo) config remote.origin.fetch +refs/heads/*:refs/remotes/origin/*"
                assert-called $sb $"git -C ($repo) fetch origin"
            })
            (check "clone <url> <name> uses the given name" {
                assert-ok (launch $sb clone https://example.com/org/thing other)
                assert-called $sb $"git clone --bare -- https://example.com/org/thing ($bare)/other.git"
            })
            (check "clone refuses an existing or invalid name" {
                mkdir ($bare | path join taken.git)
                assert-fails (launch $sb clone https://example.com/x taken)
                assert-fails (launch $sb clone https://example.com/x ../escape)
                assert-not-called $sb "git clone --bare -- https://example.com/x"
            })
        ]
    }
}

# --- 7. host-only guard --------------------------------------------------------

def test-host-only []: nothing -> list<record> {
    with-sandbox {|sb|
        let marker = $sb.dir | path join containerenv
        touch $marker
        let sb = $sb | update env.CLAUDE_WRAPPER_CONTAINERENV $marker

        [
            (check "host-only subcommands refuse to run in a container" {
                for args in [[mounts] [port open 1:2]] {
                    let r = launch $sb ...$args
                    assert equal $r.exit_code 1 $"($args) ran"
                    assert ("only runs on the host" in $r.stderr) $r.stderr
                }
                assert-not-called $sb "podman"
                assert-not-called $sb "systemd-run"
            })
        ]
    }
}

# --- 8. bootstrap through the flake when tools are missing ----------------------

def test-bootstrap []: nothing -> list<record> {
    with-sandbox {|sb|
        let bin = $sb.dir | path join bin
        for name in $BOOTSTRAP_FAKES { ln -s ($TESTS_DIR | path join fake) ($bin | path join $name) }
        let bare = $sb | reject env.CLAUDE_WRAPPER_FLAKE
        let args = [mount ($sb.dir) rw]
        touch ($sb.env.FAKE_STATE | path join running)

        [
            (check "a missing tool makes run.nu re-run itself under nix shell path:<checkout>#deps with the same arguments" {
                rm ($bin | path join claude-ns)
                let r = launch $bare ...$args
                assert-ok $r
                assert equal (calls $sb) [$"nix shell path:($REPO)#deps -c nu ($RUN) ($args | str join ' ')"]
            })
            (check "with CLAUDE_WRAPPER_FLAKE set it does not re-exec and fails as usual" {
                rm -f $sb.env.FAKE_LOG
                let r = launch $sb ...$args
                assert-fails $r
                assert ("claude-ns is not on PATH" in $r.stderr) $r.stderr
                assert-not-called $sb "nix"
            })
            (check "in a container it does not re-exec either" {
                let marker = $sb.dir | path join containerenv
                touch $marker
                rm -f $sb.env.FAKE_LOG
                let r = launch ($bare | update env.CLAUDE_WRAPPER_CONTAINERENV $marker) ...$args
                assert equal $r.exit_code 1
                assert ("only runs on the host" in $r.stderr) $r.stderr
                assert-not-called $sb "nix"
            })
            (check "with every tool on PATH it never calls nix" {
                ln -s ($TESTS_DIR | path join fake) ($bin | path join claude-ns)
                rm -f $sb.env.FAKE_LOG
                assert-ok (launch $bare ...$args)
                assert-not-called $sb "nix"
                assert-called $sb $"podman unshare claude-ns mount ($sb.env.FAKE_PID) ($sb.dir) ($sb.dir)"
            })
            (check "without nix it fails pointing at the flake" {
                rm ($bin | path join claude-ns) ($bin | path join nix)
                let r = launch ($bare | update env.PATH ([$bin (which nu | get path.0 | path dirname)] | str join ":")) "--dryrun"
                assert equal $r.exit_code 1
                assert ("flake.nix" in $r.stderr) $r.stderr
                assert ("claude-ns" in $r.stderr) $r.stderr
            })
        ]
    }
}

# --- 9. zellij config ---------------------------------------------------------

def test-zellij-config []: nothing -> list<record> {
    if (which zellij | is-empty) {
        return [(skipped "zellij setup --check" "zellij not on PATH")]
    }
    [(check "zellij setup --check accepts zellij/config.kdl" {
        let r = ^zellij --config ($REPO | path join zellij config.kdl) setup --check | complete
        assert equal $r.exit_code 0 ($r.stdout + $r.stderr)
    })]
}

# --- 10. container/start.sh: exit 75 when an update was requested --------------

# Run start.sh in the sandbox as the container would (HOME, fakes on PATH)
def start-container [sb: record]: nothing -> record {
    with-env $sb.env { ^sh ($REPO | path join container start.sh) | complete }
}

def test-start []: nothing -> list<record> {
    with-sandbox {|sb|
        [
            (check "start.sh runs claude --continue and exits 0" {
                let r = start-container $sb
                assert equal $r.exit_code 0 ($r.stderr | str trim)
                assert-called-with $sb claude ["--name Manager --continue"]
            })
            (check "start.sh's first prompt tells the Manager to arm the scheduler monitor" {
                let r = start-container $sb
                assert equal $r.exit_code 0 ($r.stderr | str trim)
                assert-called-with $sb claude ["--name Manager --continue" "Arm the scheduler monitor now"]
            })
            (check "start.sh opens the session pinned in ~/.claude/manager-session" {
                mkdir ($sb.home | path join .claude)
                "aaaaaaaa-pinned\n" | save -f ($sb.home | path join .claude manager-session)
                let r = start-container $sb
                assert equal $r.exit_code 0 ($r.stderr | str trim)
                assert-called-with $sb claude ["--name Manager --resume aaaaaaaa-pinned"]
                rm ($sb.home | path join .claude manager-session)
            })
            (check "start.sh exits 75 once claude stops after USR1" {
                touch ($sb.env.FAKE_STATE | path join request-update)
                let r = start-container $sb
                assert equal $r.exit_code 75 ($r.stderr | str trim)
                # the signalled claude was the last thing run: no fallback after it
                assert ((calls-starting-with $sb "claude " | last) | str starts-with "claude --name Manager --continue")
            })
        ]
    }
}

# --- 11. request-update.sh end to end, with start.sh as PID 1 -------------------

# unshare -Urpf --mount-proc gives a PID namespace whose PID 1 is the command,
# with a /proc to match, as start.sh is in the container; some sandboxes
# (and kernels) refuse user namespaces, so this test is skipped there
def test-container []: nothing -> list<record> {
    let probe = do { ^unshare -Urpf --mount-proc true } | complete
    if $probe.exit_code != 0 {
        return [(skipped "request-update.sh ends start.sh with 75" $"no unshare -Urpf --mount-proc: ($probe.stderr | str trim)")]
    }
    let script = $REPO | path join container request-update.sh

    with-sandbox {|sb|
        [
            (check "request-update.sh ends start.sh with 75" {
                $script | save ($sb.env.FAKE_STATE | path join request-update-script)
                let r = with-env $sb.env { ^unshare -Urpf --mount-proc sh ($REPO | path join container start.sh) | complete }
                assert equal $r.exit_code 75 ($r.stderr | str trim)
                assert ((calls-starting-with $sb "claude " | last) | str starts-with "claude --name Manager --continue")
            })
            (check "request-update.sh refuses while PID 1 is not start.sh" {
                let r = with-env $sb.env { ^unshare -Urpf --mount-proc sh -c $"sh ($script)" | complete }
                assert equal $r.exit_code 1 $r.stderr
                assert ("still starting" in $r.stderr) $r.stderr
            })
        ]
    }
}

# --- 12. bin/claude-attach: run claude-update when the container exits 75 -------

# Run claude-attach in the sandbox with the fake podman, as a Zellij pane would
def attach [sb: record]: nothing -> record {
    with-env $sb.env { ^sh ($REPO | path join bin claude-attach) --detach-keys= $NAME | complete }
}

def test-attach []: nothing -> list<record> {
    with-sandbox {|sb|
        let marker = $sb.env.XDG_RUNTIME_DIR | path join updating
        let attach_call = $"podman attach --detach-keys= ($NAME)"
        let sb = $sb | upsert env.CLAUDE_WRAPPER_UPDATING $marker
        touch ($sb.env.FAKE_STATE | path join running) ($sb.env.FAKE_STATE | path join exists)

        [
            (check "claude-attach exits 0 while the container runs" {
                let r = attach $sb
                assert equal $r.exit_code 0 ($r.stderr | str trim)
                assert equal (calls-starting-with $sb $attach_call | length) 1
                assert-not-called $sb "claude-update"
            })
            (check "claude-attach runs claude-update on 75 and reattaches" {
                touch ($sb.env.FAKE_STATE | path join attach-75)
                let r = attach $sb
                assert equal $r.exit_code 0 ($r.stderr | str trim)
                assert equal (calls-starting-with $sb "claude-update" | length) 1
                assert equal (calls-starting-with $sb $attach_call | length) 3
            })
            (check "claude-attach exits 75 when the container is gone after a failed update" {
                touch ($sb.env.FAKE_STATE | path join update-fails) ($sb.env.FAKE_STATE | path join attach-75)
                let r = attach $sb
                assert equal $r.exit_code 75 ($r.stderr | str trim)
                assert equal (calls-starting-with $sb "claude-update" | length) 2
                assert equal (calls-starting-with $sb $attach_call | length) 4
            })
            (check "claude-attach exits 75 without a Zellij session's claude-update" {
                rm ($sb.env.FAKE_STATE | path join update-fails)
                touch ($sb.env.FAKE_STATE | path join running) ($sb.env.FAKE_STATE | path join exists) ($sb.env.FAKE_STATE | path join attach-75)
                let r = attach ($sb | reject env.CLAUDE_WRAPPER_UPDATING)
                assert equal $r.exit_code 75 ($r.stderr | str trim)
                assert equal (calls-starting-with $sb "claude-update" | length) 2
            })
        ]
    }
}

# --- 13. services.sh ----------------------------------------------------------

def test-services []: nothing -> list<record> {
    with-sandbox {|sb|
        let services = $sb.home | path join claude .services
        let svc = $services | path join svc
        let bundle = $sb.dir | path join bundled
        mkdir $svc ($bundle | path join shipped)
        "#!/bin/sh\necho hello $PORT\nexec sleep 300\n" | save ($svc | path join run)
        "PORT=1234\n" | save ($svc | path join env)
        "#!/bin/sh\nexec sleep 300\n" | save ($bundle | path join shipped run)
        "PORT=9\n" | save ($bundle | path join shipped env)
        chmod +x ($svc | path join run) ($bundle | path join shipped run)
        let vars = $sb.env | merge {CLAUDE_SERVICES_BUNDLED: $bundle}
        let cs = {|...args| with-env $vars { ^sh $SERVICES ...$args | complete } }
        let pidfile = $svc | path join pid
        let alive = {|| (do { ^kill -0 (open --raw $pidfile | str trim) } | complete).exit_code == 0 }

        let results = [
            (check "start runs the service with its env and logs its output" {
                assert-ok (do $cs start svc)
                sleep 300ms
                assert (do $alive) "supervisor pid is not alive"
                let logs = do $cs logs svc
                assert-ok $logs
                assert ("hello 1234" in $logs.stdout) $logs.stdout
            })
            (check "list shows name, port and state" {
                let r = do $cs list
                assert-ok $r
                assert ($r.stdout =~ 'svc\t1234\trunning \d+') $r.stdout
            })
            (check "start is idempotent" {
                let pid = open --raw $pidfile
                assert-ok (do $cs start svc)
                assert equal (open --raw $pidfile) $pid
            })
            (check "stop kills the supervisor and the service" {
                let pid = open --raw $pidfile | str trim
                assert-ok (do $cs stop svc)
                sleep 300ms
                assert (not ($pidfile | path exists)) "pid file left behind"
                assert ((do { ^kill -0 $pid } | complete).exit_code != 0) "supervisor still alive"
                assert ((do $cs list).stdout =~ 'svc\t1234\tstopped') "not listed as stopped"
            })
            (check "a stale pid counts as stopped" {
                "999999\n" | save -f $pidfile
                assert-ok (do $cs start svc)
                sleep 300ms
                assert (do $alive) "service not restarted over a stale pid"
                assert-ok (do $cs stop svc)
            })
            (check "start refuses bad names and missing run scripts" {
                assert-fails (do $cs start "../svc")
                assert-fails (do $cs start nope)
            })
            (check "install-bundled copies shipped services and marks them" {
                assert-ok (do $cs install-bundled)
                let d = $services | path join shipped
                assert ($d | path join .from-wrapper | path exists) "marker missing"
                assert equal (open --raw ($d | path join env)) "PORT=9\n"
            })
            (check "install-bundled refreshes a marked copy but keeps its env" {
                let d = $services | path join shipped
                "PORT=10\n" | save -f ($d | path join env)
                "#!/bin/sh\nexec sleep 301\n" | save -f ($bundle | path join shipped run)
                assert-ok (do $cs install-bundled)
                assert equal (open --raw ($d | path join env)) "PORT=10\n"
                assert ("sleep 301" in (open --raw ($d | path join run))) "run not refreshed"
            })
            (check "install-bundled copies the shipped env again when the installed one is missing" {
                let d = $services | path join shipped
                rm ($d | path join env)
                assert-ok (do $cs install-bundled)
                assert equal (open --raw ($d | path join env)) "PORT=9\n"
                "PORT=10\n" | save -f ($d | path join env)
            })
            (check "install-bundled leaves an unmarked service alone" {
                let d = $services | path join shipped
                rm ($d | path join .from-wrapper)
                "#!/bin/sh\nexec sleep 302\n" | save -f ($bundle | path join shipped run)
                let r = do $cs install-bundled
                assert-ok $r
                assert ("not refreshed" in $r.stderr) $r.stderr
                assert ("sleep 301" in (open --raw ($d | path join run))) "run was clobbered"
            })
            (check "start-all skips disabled services" {
                touch ($services | path join shipped disabled)
                assert-ok (do $cs start-all)
                sleep 300ms
                let r = do $cs list
                assert ($r.stdout =~ 'shipped\t10\tdisabled') $r.stdout
                assert ($r.stdout =~ 'svc\t1234\trunning') $r.stdout
            })
            (check "install-bundled copies a shipped disabled marker only the first time" {
                rm ($services | path join shipped disabled)
                touch ($services | path join shipped .from-wrapper) ($bundle | path join shipped disabled)
                assert-ok (do $cs install-bundled)
                assert (not ($services | path join shipped disabled | path exists)) "disabled added to an installed service"
                rm -rf ($services | path join shipped)
                assert-ok (do $cs install-bundled)
                assert ($services | path join shipped disabled | path exists) "disabled missing on first install"
            })
        ]
        do $cs stop svc | ignore
        $results
    }
}

# --- 14. usage-db importer ----------------------------------------------------

def test-usage-db []: nothing -> list<record> {
    with-sandbox {|sb|
        let jsonl = $sb.dir | path join usage.jsonl
        let db = $sb.dir | path join usage.sqlite
        let sample = {|ts, session, cost| {ts: $ts, session_id: $session, model: m, five_hour_used: 10, seven_day_used: 20, context_used_percentage: 30, cost_usd: $cost, cwd: "/x"} | to json --raw }
        [(do $sample 1000 a 0.5) (do $sample 1060 a 1.0) (do $sample 1060 b null) "" (do $sample 1000 a 0.5)] | str join "\n" | save $jsonl
        let count = {|| open $db | query db "select count(*) n from samples" | get 0.n }
        let import = {|| with-env $sb.env { ^nu $IMPORT $jsonl $db | complete } }

        [
            (check "import loads the samples, deduplicated on ts + session_id" {
                assert-ok (do $import)
                assert equal (do $count) 3
                let b = open $db | query db "select cost_usd, model from samples where session_id = 'b'"
                assert equal $b [{cost_usd: null, model: m}]
            })
            (check "message_costs takes the latest price row whose since is not after the message, 1h cache writes at their own rate" {
                open $db | query db "insert into prices values ('claude-fable-5-1', '2026-10-15', 1, 2, 3, 4, 5)" | ignore
                open $db | query db "insert into messages (id, ts, model, input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens, cache_creation_1h_input_tokens) values ('old', 1791990000, 'claude-fable-5-1', 1000000, 0, 0, 0, 0), ('new', 1792058400, 'claude-fable-5-1', 1000000, 0, 2000000, 0, 1000000)" | ignore
                let c = open $db | query db "select id, since, round(cost_usd, 6) cost_usd from message_costs where id in ('old', 'new') order by id"
                assert equal $c [{id: new, since: "2026-10-15", cost_usd: 8.0} {id: old, since: "2026-01-01", cost_usd: 10.0}]
                open $db | query db "delete from messages where id in ('old', 'new')" | ignore
                assert-ok (do $import) # refresh-prices drops the extra row again
                assert equal (open $db | query db "select count(*) n from prices where family = 'claude-fable-5-1'" | get 0.n) 1
            })
            (check "import again adds nothing" {
                assert-ok (do $import)
                assert equal (do $count) 3
            })
            (check "import picks up appended lines" {
                $"\n(do $sample 1120 b 2.0)\n" | save --append $jsonl
                assert-ok (do $import)
                assert equal (do $count) 4
            })
            (check "import starts over on a rewritten shorter file" {
                [(do $sample 1000 a 0.5) (do $sample 5000 c 0)] | str join "\n" | save -f $jsonl
                assert-ok (do $import)
                assert equal (do $count) 5
            })
            (check "import keeps one meta row and does not re-insert null-session samples" {
                $"\n(do $sample 6000 null 1.0)\n" | save --append $jsonl
                assert-ok (do $import)
                assert-ok (do $import)
                assert equal (do $count) 6
                assert equal (open $db | query db "select count(*) n from meta" | get 0.n) 1
                assert equal (open $db | query db "select value from meta where key = 'lines'" | get 0.value) 3
            })
            (check "budget_deltas attributes each rise in five_hour_used to the sample's session, dropping resets" {
                let budget = $sb.dir | path join budget.sqlite
                let s = {|ts, session, used| {ts: $ts, session_id: $session, model: m, five_hour_used: $used} | to json --raw }
                # a: 10 -> 15; b (other session) 15 -> 25; a: 25 -> 40; reset to 5 (left out); b: 5 -> 7
                [(do $s 100 a 10) (do $s 200 a 15) (do $s 300 b 25) (do $s 400 a 40) (do $s 500 a 5) (do $s 600 b 7)] | str join "\n" | save ($sb.dir | path join budget.jsonl)
                assert-ok (with-env $sb.env { ^nu $IMPORT ($sb.dir | path join budget.jsonl) $budget --projects ($sb.dir | path join none) | complete })
                let deltas = open $budget | query db "select ts, session_id, delta from budget_deltas order by ts"
                assert equal $deltas [{ts: 200, session_id: a, delta: 5.0} {ts: 300, session_id: b, delta: 10.0} {ts: 400, session_id: a, delta: 15.0} {ts: 600, session_id: b, delta: 2.0}]
                # sourced rather than run so the result is a table, not an 80-column rendering
                let usage = {|by| with-env $sb.env { ^nu -c $"source '($REPO | path join bin claude-usage)'; main db budget --db '($budget)' --by ($by) | to json" | complete } }
                let r = do $usage session
                assert-ok $r
                assert equal ($r.stdout | from json | select session_id samples five_hour_points) [{session_id: a, samples: 2, five_hour_points: 20.0} {session_id: b, samples: 2, five_hour_points: 12.0}]
                assert equal (do $usage model | get stdout | from json) [{model: m, sessions: 2, samples: 4, five_hour_points: 32.0}]
                assert equal (do $usage hour | get stdout | from json) [{hour: "1970-01-01 00:00", sessions: 2, five_hour_points: 32.0}]
                assert-fails (do $usage day)
            })
            (check "import migrates a database whose meta has no primary key" {
                let old = $sb.dir | path join old.sqlite
                [{key: lines, value: 1} {key: lines, value: 2}] | into sqlite $old -t meta
                open $old | query db "create table samples (ts integer not null, session_id text, model text, five_hour_used real, five_hour_resets_at integer, seven_day_used real, seven_day_resets_at integer, context_used_percentage real, context_window_size integer, total_input_tokens integer, total_output_tokens integer, cost_usd real, duration_ms integer, lines_added integer, lines_removed integer, version text, cwd text, unique (ts, session_id))" | ignore
                open $old | query db "insert into samples (ts, session_id) values (1, null), (1, null), (2, 'x')" | ignore
                assert-ok (with-env $sb.env { ^nu $IMPORT $jsonl $old | complete })
                assert equal (open $old | query db "select value from meta" | get value) [3]
                assert equal (open $old | query db "select count(*) n from samples" | get 0.n) 3
            })
        ]
    }
}

# --- 15. transcript importer ---------------------------------------------------

# A transcript record the way Claude Code writes assistant messages (one record
# per content block, repeating the usage); `agent` sets the subagent fields
def transcript-record [id: string, uuid: string, ts: string, model: string, usage: record, --agent: string]: nothing -> string {
    {
        type: assistant, uuid: $uuid, timestamp: $ts, sessionId: s1, cwd: "/x", version: "2.1.300"
        message: {id: $id, model: $model, role: assistant, usage: $usage}
    }
    | merge (if $agent == null { {} } else { {agentId: $agent, attributionAgent: general-purpose, isSidechain: true} })
    | to json --raw
}

def test-transcripts []: nothing -> list<record> {
    with-sandbox {|sb|
        let projects = $sb.dir | path join projects
        let db = $sb.dir | path join usage.sqlite
        let main_file = $projects | path join p s1.jsonl
        let agent_file = $projects | path join p s1 subagents agent-a1.jsonl
        let a2 = $projects | path join p s1 subagents agent-a2.jsonl
        mkdir ($agent_file | path dirname)
        let usage = {input_tokens: 100, output_tokens: 10, cache_creation_input_tokens: 1000, cache_read_input_tokens: 10000}
        [
            (transcript-record m1 u1 "2026-10-15T10:00:00.000Z" claude-fable-5-1 $usage)
            (transcript-record m1 u2 "2026-10-15T10:00:00.500Z" claude-fable-5-1 $usage)
            ({type: user, uuid: u3, timestamp: "2026-10-15T10:00:01.000Z", sessionId: s1, message: {role: user, content: "hi"}} | to json --raw)
            "not json {"
            (transcript-record m2 u4 "2026-10-15T11:00:00.000Z" claude-sonnet-5-5 {input_tokens: 1000000, output_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0})
        ] | str join "\n" | $"($in)\n" | save $main_file
        $"(transcript-record m3 u5 "2026-10-15T10:30:00.000Z" claude-fable-5-1 $usage --agent a1)\n" | save $agent_file
        let count = {|| open $db | query db "select count(*) n from messages" | get 0.n }
        let import = {|| with-env $sb.env { ^nu $IMPORT ($sb.dir | path join none.jsonl) $db --projects $projects | complete } }
        let cost = {|...args| with-env $sb.env { ^nu ($REPO | path join bin claude-usage) db cost --db $db --source transcripts ...$args | complete } }

        [
            (check "import loads one row per API message, keyed on message id, with all four token counts" {
                assert-ok (do $import)
                assert equal (do $count) 3
                let m1 = open $db | query db "select uuid, ts, session_id, agent_id, agent_type, model, input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens from messages where id = 'm1'"
                assert equal $m1 [{uuid: u1, ts: 1792058400, session_id: s1, agent_id: null, agent_type: null, model: claude-fable-5-1, input_tokens: 100, output_tokens: 10, cache_creation_input_tokens: 1000, cache_read_input_tokens: 10000}]
                let m3 = open $db | query db "select agent_id, agent_type from messages where id = 'm3'"
                assert equal $m3 [{agent_id: a1, agent_type: general-purpose}]
            })
            (check "message_costs prices by the longest model family prefix" {
                let c = open $db | query db "select id, family, round(cost_usd, 6) cost_usd from message_costs order by id"
                # fable 5.1: 100 * 10 + 10 * 50 + 1000 * 12.5 + 10000 * 0.25 = 16500 / 1e6
                assert equal $c [{id: m1, family: claude-fable-5-1, cost_usd: 0.0165} {id: m2, family: claude-sonnet-5-5, cost_usd: 2.0} {id: m3, family: claude-fable-5-1, cost_usd: 0.0165}]
            })
            (check "import again adds nothing" {
                let r = do $import
                assert-ok $r
                assert equal (do $count) 3
                assert ($r.stdout =~ "0 new messages, 3 in total") $r.stdout
            })
            (check "import picks up appended records and restarts on a rewritten file" {
                $"\n(transcript-record m4 u6 "2026-10-15T12:00:00.000Z" claude-fable-5-1 $usage)\n" | save --append $main_file
                assert-ok (do $import)
                assert equal (do $count) 4
                $"(transcript-record m5 u7 "2026-10-15T13:00:00.000Z" claude-fable-5-1 $usage)\n" | save -f $main_file
                assert-ok (do $import)
                assert equal (do $count) 5
                # rewritten to the same size: the first line changed, so it is read again from the start
                $"(transcript-record m9 u9 "2026-10-15T13:00:00.000Z" claude-fable-5-1 $usage)\n" | save -f $main_file
                assert-ok (do $import)
                assert equal (do $count) 6
            })
            (check "import transcript <file> imports one file" {
                $"(transcript-record m6 u8 "2026-10-15T13:00:00.000Z" claude-fable-5-1 $usage --agent a2)\n" | save $a2
                let r = with-env $sb.env { ^nu $IMPORT transcript $a2 $db | complete }
                assert-ok $r
                assert ($r.stdout =~ "1 new messages") $r.stdout
                assert equal (do $count) 7
            })
            (check "the Stop hook imports the transcript named on stdin in the background" {
                let hook = {|input, extra = {}| with-env ($sb.env | merge {CLAUDE_USAGE_DB_DIR: $sb.dir, CLAUDE_USAGE_IMPORT: $IMPORT} | merge $extra) { $input | ^sh ($REPO | path join container usage-hook.sh) | complete } }
                let settle = {|n| for _ in 1..20 { if (do $count) == $n { break }; sleep 250ms }; do $count }
                $"\n(transcript-record m7 u9 "2026-10-15T14:00:00.000Z" claude-fable-5-1 $usage --agent a2)\n" | save --append $a2
                assert-ok (do $hook ({agent_transcript_path: $a2, transcript_path: $main_file} | to json))
                assert equal (do $settle 8) 8
                # a record appended without its newline yet is left for the next import
                $"\n(transcript-record m8 u10 "2026-10-15T15:00:00.000Z" claude-fable-5-1 $usage --agent a2)" | save --append $a2
                assert-ok (do $hook ({agent_transcript_path: $a2} | to json))
                sleep 500ms
                assert equal (do $count) 8
                "\n" | save --append $a2
                assert-ok (do $hook ({agent_transcript_path: $a2} | to json))
                assert equal (do $settle 9) 9
                assert ((open --raw ($sb.dir | path join log)) =~ "new messages") "hook output not in the service log"
                # no input, a missing file or no database yet: nothing to do
                assert-ok (do $hook "")
                assert-ok (do $hook ({transcript_path: ($sb.dir | path join nope.jsonl)} | to json))
                mkdir ($sb.dir | path join nodb)
                assert-ok (do $hook ({transcript_path: $main_file} | to json) {CLAUDE_USAGE_DB_DIR: ($sb.dir | path join nodb)})
                sleep 300ms
                assert equal (ls ($sb.dir | path join nodb) | length) 0
            })
            (check "claude-usage db cost --source transcripts groups by day, session, model and agent" {
                let r = do $cost "--by" agent
                assert-ok $r
                assert ($r.stdout =~ 'main\s+│\s+1\s+│\s+5') $r.stdout
                assert ($r.stdout =~ 'general-purpose\s+│\s+2\s+│\s+4') $r.stdout
                for by in [day session model] { assert-ok (do $cost "--by" $by) }
                assert-fails (do $cost "--by" agent "--source" samples)
            })
        ]
    }
}

# --- 16. proxy config ---------------------------------------------------------

def test-proxy []: nothing -> list<record> {
    with-sandbox {|sb|
        let services = $sb.home | path join claude .services
        for s in [[name port]; [one 9001] [two 9002] [noport ""] [Upper 9003] [badport 99999] [proxy 8080] [dashboard 8422]] {
            mkdir ($services | path join $s.name)
            "#!/bin/sh\nexec sleep 300\n" | save ($services | path join $s.name run)
            chmod +x ($services | path join $s.name run)
            if $s.port != "" { $"PORT=($s.port)\n" | save ($services | path join $s.name env) }
        }
        let caddyfile = $services | path join proxy Caddyfile
        let cs = {|...args| with-env $sb.env { ^sh $SERVICES ...$args | complete } }
        let routes = {|| open --raw $caddyfile | parse -r 'handle_path /(?<name>[^/]+)/\* \{\s*reverse_proxy 127.0.0.1:(?<port>\d+)' }

        let hash = '$2a$14$0ZCHTjueUZA2fhKn4itMdumpUv5wrCLSY87riyJ9/SNngAMWtZsTS'

        let results = [
            (check "without a users file the proxy only answers 403" {
                for s in [one two noport] { assert-ok (do $cs start $s) }
                sleep 300ms
                let conf = open --raw $caddyfile
                assert ($conf =~ 'respond ".*claude-services proxy-password.*" 403') $conf
                assert equal (do $routes) []
                assert ("basic_auth" not-in $conf) "basic_auth without users"
            })
            (check "a users file with no account line is the same as none" {
                "# nothing here\nclaude not-a-hash\n" | save ($services | path join proxy users)
                assert-ok (do $cs proxy-config)
                let conf = open --raw $caddyfile
                assert ($conf =~ 'respond ".*claude-services proxy-password.*" 403') $conf
                assert ("basic_auth" not-in $conf) "basic_auth without accounts"
            })
            (check "start writes a route per running service with a PORT, not the proxy, behind basic_auth" {
                $"claude ($hash)\n" | save -f ($services | path join proxy users)
                assert-ok (do $cs start one)
                let conf = open --raw $caddyfile
                assert equal (do $routes) [{name: one, port: "9001"} {name: two, port: "9002"}]
                assert ("http://127.0.0.1:8080 {" in $conf) "proxy port missing"
                assert ("admin 127.0.0.1:2919" in $conf) "admin address not taken from CLAUDE_PROXY_ADMIN"
                assert ($"basic_auth {\n\t\tclaude ($hash)\n\t}" in $conf) $conf
                assert ('<a href="/one/">one</a>' in $conf) "index link missing"
                assert ("403" not-in $conf) "403 stub with users"
                assert ("grace_period 5s" in $conf) "grace_period missing"
                assert ($conf =~ 'handle \{\s*respond 404\s*\}\s*\}\s*$') "no 404 fallback at the end"
            })
            (if (which caddy nix | is-empty) { skipped "caddy validate accepts the Caddyfile" "neither caddy nor nix on PATH" } else {
                check "caddy validate accepts the Caddyfile" {
                    let args = [validate --config $caddyfile --adapter caddyfile]
                    let r = if (which caddy | is-not-empty) { ^caddy ...$args | complete } else { ^nix shell nixpkgs#caddy -c caddy ...$args | complete }
                    assert equal $r.exit_code 0 $r.stderr
                }
            })
            (check "a name that is not lowercase or a PORT that is not a port gets no route, with a warning" {
                for s in [Upper badport] { assert-ok (do $cs start $s) }
                let r = do $cs proxy-config
                assert-ok $r
                assert equal (do $routes) [{name: one, port: "9001"} {name: two, port: "9002"}]
                assert ("skipping Upper" in $r.stderr) $r.stderr
                assert ("skipping badport" in $r.stderr) $r.stderr
            })
            (check "a pid file naming another service's loop reads as stopped" {
                # one-two's loop is alive and its argv contains "one"; one must not pass as running
                mkdir ($services | path join one-two)
                cp ($services | path join one run) ($services | path join one-two run)
                assert-ok (do $cs start one-two)
                assert-ok (do $cs stop one)
                cp ($services | path join one-two pid) ($services | path join one pid)
                let listed = (do $cs list).stdout | lines | parse "{name}\t{port}\t{state}"
                assert equal ($listed | where name == one | get 0.state) stopped
                assert ($listed | where name == one-two | get 0.state | str starts-with running) "one-two not running"
                assert-ok (do $cs stop one-two)
                assert-ok (do $cs start one)
            })
            (check "stop drops the service's route" {
                assert-ok (do $cs stop one)
                assert equal (do $routes) [{name: two, port: "9002"}]
            })
            (check "a running dashboard takes / and the index moves to /services/" {
                assert-ok (do $cs start dashboard)
                let conf = open --raw $caddyfile
                assert equal (do $routes) [{name: two, port: "9002"}]
                assert ($conf =~ 'handle /services/ \{[^}]*respond `') "index not at /services/"
                assert ($conf =~ 'handle \{\s*reverse_proxy 127.0.0.1:8422\s*\}\s*\}\s*$') "dashboard not at /"
                assert-ok (do $cs stop dashboard)
                assert ($"handle / {" in (open --raw $caddyfile)) "index not back at /"
                assert ("/services/" in (open --raw $caddyfile)) "no /services/"
            })
        ]
        for s in [one two noport Upper badport dashboard] { do $cs stop $s | ignore }
        $results
    }
}

# --- 17. claude-emacs: the forms it sends through emacsclient --------------------

def test-emacs-cli []: nothing -> list<record> {
    with-sandbox {|sb|
        let service = $sb.home | path join claude .services emacs
        let socket = $service | path join socket server
        mkdir ($socket | path dirname)
        let ce = {|...args| with-env $sb.env { ^nu $CLAUDE_EMACS ...$args | complete } }
        let sent = {|| calls-starting-with $sb "emacsclient " | last | str replace $"emacsclient -s ($socket) -e " "" }

        [
            (check "without the socket every command exits 2 naming claude-services" {
                let r = do $ce ping
                assert equal $r.exit_code 2
                assert ("claude-services start emacs" in $r.stderr) $r.stderr
                assert-not-called $sb "emacsclient"
            })
            (check "ping evaluates t against the socket" {
                touch $socket
                let r = do $ce ping
                assert-ok $r
                assert equal ($r.stdout | str trim) ok
                assert equal (do $sent) "t"
            })
            (check "open sends claude-open with the absolute path and the line" {
                assert-ok (do $ce open ($sb.dir | path join "a b.txt") 12)
                assert equal (do $sent) $"\(claude-open \"($sb.dir)/a b.txt\" 12)"
                assert-ok (do $ce open /tmp/x)
                assert equal (do $sent) '(claude-open "/tmp/x")'
            })
            (check "diff sends claude-diff" {
                assert-ok (do $ce diff /tmp/a /tmp/b)
                assert equal (do $sent) '(claude-diff "/tmp/a" "/tmp/b")'
            })
            (check "report sends claude-report with an optional title" {
                assert-ok (do $ce report /tmp/r.md)
                assert equal (do $sent) '(claude-report "/tmp/r.md")'
                assert-ok (do $ce report /tmp/r.md title "Plan \"v2\"")
                assert equal (do $sent) '(claude-report "/tmp/r.md" "Plan \"v2\"")'
                let r = do $ce report /tmp/r.md bogus x
                assert equal $r.exit_code 1
                assert ("[title <value>]" in $r.stderr) $r.stderr
            })
            (check "say escapes backslashes and quotes" {
                assert-ok (do $ce say 'a\b "c"')
                assert equal (do $sent) '(claude-say "a\\b \"c\"")'
            })
            (check "ask prints the answer file written for its id and removes it" {
                "yes\n" | save ($sb.env.FAKE_STATE | path join answer)
                let r = do $ce ask "Merge?"
                assert-ok $r
                assert equal $r.stdout "yes\n"
                assert ((do $sent) =~ '^\(claude-ask "Merge\?" "[0-9]+-[A-Za-z0-9]+"\)$') (do $sent)
                assert equal (ls ($service | path join answers) | length) 0
                rm ($sb.env.FAKE_STATE | path join answer)
            })
            (check "ask exits 1 when declined" {
                touch ($sb.env.FAKE_STATE | path join decline)
                assert equal (do $ce ask "Merge?").exit_code 1
                rm ($sb.env.FAKE_STATE | path join decline)
            })
            (check "ask leaves another ask's pending answer alone and clears day-old leftovers" {
                let answers = $service | path join answers
                "for A\n" | save ($answers | path join 1-other)
                touch ($answers | path join 0-old)
                ^touch -d "2 days ago" ($answers | path join 0-old)
                "B\n" | save ($sb.env.FAKE_STATE | path join answer)
                let r = do $ce ask "B?"
                rm ($sb.env.FAKE_STATE | path join answer)
                assert-ok $r
                assert equal $r.stdout "B\n"
                assert equal (open --raw ($answers | path join 1-other)) "for A\n"
                assert (not ($answers | path join 0-old | path exists)) "day-old answer kept"
                rm ($answers | path join 1-other)
            })
            (check "ask exits 3 on timeout and marks its buffer timed out" {
                let r = do $ce ask "Still there?" timeout 1
                assert equal $r.exit_code 3
                assert ("timed out" in $r.stderr) $r.stderr
                assert ((do $sent) =~ '^\(claude-ask-timeout "[0-9]+-[A-Za-z0-9]+"\)$') (do $sent)
                assert equal (ls ($service | path join answers) | length) 0
            })
        ]
    }
}

# --- 18. c emacs: a frame with the host's emacsclient ----------------------------

def test-emacs-frame []: nothing -> list<record> {
    with-sandbox {|sb|
        let socket = $sb.home | path join claude .services emacs socket server
        [
            (check "c emacs starts the service through podman when there is no socket, then opens a frame" {
                assert-ok (launch $sb "--detach")
                let r = launch $sb emacs
                assert-ok $r
                assert-called $sb $"podman exec ($NAME) claude-services start emacs"
                assert-called $sb $"emacsclient -s ($socket) -n -c -e \(claude-open-dir \"($sb.home | path join claude)\")"
            })
            (check "c emacs <file> <line> passes +line and the absolute path" {
                assert-ok (launch $sb emacs notes.md 7)
                assert equal (calls-starting-with $sb "podman exec" | length) 1
                assert-called $sb $"emacsclient -s ($socket) -n -c +7 (pwd)/notes.md"
            })
            (check "c emacs fails with the fix when the container is not running" {
                rm $socket
                rm ($sb.env.FAKE_STATE | path join running)
                let before = calls-starting-with $sb "emacsclient" | length
                let r = launch $sb emacs
                assert-fails $r
                assert ("could not start it" in $r.stderr) $r.stderr
                assert equal (calls-starting-with $sb "emacsclient" | length) $before
            })
        ]
    }
}

# --- 19. init.el and claude.el load in a bare Emacs --------------------------------

def test-emacs-init []: nothing -> list<record> {
    let name = "emacs --batch loads init.el and claude.el; concurrent asks answer separately, a timed-out one not at all"
    let emacs = if (which emacs | is-not-empty) { [emacs] } else if (which nix | is-not-empty) {
        [nix shell nixpkgs#emacs-nox -c emacs]
    } else { return [(skipped $name "neither emacs nor nix on PATH")] }

    with-sandbox {|sb|
        let service = $sb.home | path join claude .services emacs
        let report = $sb.dir | path join report.md
        "# Hello\n" | save $report
        let forms = $"\(progn
            \(claude-say \"hi\")
            \(claude-report \"($report)\" \"Report\")
            \(claude-ask \"Merge?\" \"id1\")
            \(claude-ask \"Again?\" \"id2\")
            \(claude-ask \"Late?\" \"id3\")
            \(with-current-buffer \"*claude ask id2*\" \(claude-ask-decline))
            \(with-current-buffer \"*claude ask id1*\" \(goto-char \(point-max)) \(insert \"  yes\n\") \(claude-ask-submit))
            \(claude-ask-timeout \"id3\")
            \(with-current-buffer \"*claude ask id3*\" \(goto-char \(point-max)) \(insert \"no\") \(claude-ask-submit))
            \(princ \(format \"report=%s state=%s\\n\" \(buffer-name \(get-buffer \"*claude report: Report*\")) user-emacs-directory)))"
        let r = with-env $sb.env {
            run-external ...($emacs | append [--batch -l ($EMACS_CONF | path join early-init.el) -l ($EMACS_CONF | path join init.el) --eval $forms]) | complete
        }
        [(check $name {
            assert equal $r.exit_code 0 $"($r.stdout)\n($r.stderr)"
            assert ($"report=*claude report: Report* state=($service)/state/" in $r.stdout) $r.stdout
            assert equal (open --raw ($service | path join answers id1)) "yes"
            assert ($service | path join answers id2.declined | path exists) "declined marker missing"
            assert (not ($service | path join answers id3 | path exists)) "a timed-out ask delivered its answer"
        })]
    }
}
