#!/usr/bin/env nu
# The test suite (`just test`): lints every script, then drives run.nu,
# container/start.sh, container/request-update.sh and bin/claude-attach
# against fake podman/systemd-run/systemctl/git/claude in a throwaway HOME and
# asserts on what they tried to run. Nothing real is touched.

use std/assert

const TESTS_DIR: string = path self | path expand | path dirname
const REPO = $TESTS_DIR | path dirname
const RUN = $REPO | path join run.nu
const NAME = "claude-manager"
const FAKES = [podman systemd-run systemctl git xdg-dbus-proxy claude-ns claude-update claude]
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

    {
        dir: $dir
        home: ($dir | path join home)
        env: {
            HOME: ($dir | path join home)
            XDG_CONFIG_HOME: ($dir | path join xdg-config)
            XDG_DATA_HOME: ($dir | path join xdg-data)
            XDG_CACHE_HOME: ($dir | path join xdg-cache)
            XDG_RUNTIME_DIR: ($dir | path join runtime)
            CLAUDE_WRAPPER_CONTAINERENV: ($dir | path join not-a-container)
            CLAUDE_WRAPPER_FLAKE: "1"
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
def relay-call [sb: record, dir: string, proto: string, host: int, container: int]: nothing -> string {
    let pid = $sb.env.FAKE_PID
    let unit = port-unit $dir $proto $host $container
    let relay = if $dir == in { $"inbound ($proto) ($host) ($container)" } else { $"outbound ($proto) ($container) ($host)" }
    $"systemd-run --user --collect --quiet --unit=($unit) --description=claude port relay ($host):($container)/($proto) pid ($pid) podman unshare claude-ns relay ($pid) ($relay)"
}

def shebang [file: path]: nothing -> string {
    open --raw $file | lines | first | default ""
}

# --- 1. lint -----------------------------------------------------------------

def test-lint []: nothing -> list<record> {
    let scripts = [run.nu] | append (ls ($REPO | path join bin) | get name | path relative-to $REPO)
    | append [container/entrypoint.sh container/start.sh container/request-update.sh container/statusline.sh tests/fake tests/run.nu]
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
        [{host: 8080, container: 3000, proto: tcp, from_host: false}] | to nuon | save ($config | path join ports.nuon)

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
                    "--volume=claude-nix:/nix"
                ] --tail [claude]
            })
            (check "--detach reapplies saved mounts" {
                assert-called $sb $"podman unshare claude-ns mount ($pid) ($mounted) ($mounted) --ro"
            })
            (check "--detach reapplies saved ports" {
                assert-called $sb (relay-call $sb in tcp 8080 3000)
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
    }
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
            (check "mount <path> --rw binds read-write" {
                assert-ok (launch $sb mount $rw "--rw")
                assert-called $sb $"podman unshare claude-ns mount ($pid) ($rw) ($rw)"
                assert equal (open $file) [{path: $ro, mode: ro} {path: $rw, mode: rw}]
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
            (check "port open <host>:<container> relays inbound tcp" {
                assert-ok (launch $sb port open 8080:3000)
                assert-called $sb $"systemctl --user stop (port-unit in tcp 8080 3000).service"
                assert-called $sb (relay-call $sb in tcp 8080 3000)
                assert equal (open $file) [{host: 8080, container: 3000, proto: tcp, from_host: false}]
            })
            (check "port open --from-host relays outbound" {
                assert-ok (launch $sb port open 5432:5433/udp "--from-host")
                assert-called $sb (relay-call $sb out udp 5432 5433)
                assert equal (open $file) [
                    {host: 8080, container: 3000, proto: tcp, from_host: false}
                    {host: 5432, container: 5433, proto: udp, from_host: true}
                ]
            })
            (check "port open replaces an existing relay instead of duplicating it" {
                assert-ok (launch $sb port open 8080:3000/tcp)
                assert equal (open $file | length) 2
            })
            (check "port open rejects bad specs" {
                for spec in ["a:b" "0:80" "80:70000" "1:2/sctp" "8080:"] {
                    assert-fails (launch $sb port open $spec)
                }
                assert equal (open $file | length) 2
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
                assert-ok (launch $sb port close 5432:5433/udp "--from-host")
                assert-called $sb $"systemctl --user stop (port-unit out udp 5432 5433).service"
                assert-called $sb $"systemctl --user reset-failed (port-unit out udp 5432 5433).service"
                assert equal (open $file) [{host: 8080, container: 3000, proto: tcp, from_host: false}]
            })
            (check "port open only saves when the container is not running" {
                rm ($sb.env.FAKE_STATE | path join running)
                assert-ok (launch $sb port open 9000:9000)
                assert-not-called $sb (relay-call $sb in tcp 9000 9000)
                assert equal (open $file | length) 2
            })
        ]
    }
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
        let args = [mount ($sb.dir) --rw]
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
                assert-called $sb "claude --name Manager --continue"
            })
            (check "start.sh exits 75 once claude stops after USR1" {
                touch ($sb.env.FAKE_STATE | path join request-update)
                let r = start-container $sb
                assert equal $r.exit_code 75 ($r.stderr | str trim)
                # the signalled claude was the last thing run: no fallback after it
                assert equal (calls-starting-with $sb "claude " | last) "claude --name Manager --continue"
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
                assert equal (calls-starting-with $sb "claude " | last) "claude --name Manager --continue"
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
