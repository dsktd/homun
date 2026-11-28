#!/usr/bin/env nu
# Launcher for the Manager container. Host-only subcommands refuse to run where
# /run/.containerenv exists; HOMUN_CONTAINERENV points them at another
# marker file (the test suite uses it to run inside the container).

use std/log

const SELF: string = path self | path expand
const SCRIPT_DIR: string = $SELF | path dirname
const LIB = $SCRIPT_DIR | path join lib

use ($LIB | path join busy.nu)
use ($LIB | path join clone.nu)
use ($LIB | path join hostcfg.nu)
use ($LIB | path join homuncfg.nu)
use ($LIB | path join mounts.nu)
use ($LIB | path join need.nu)
use ($LIB | path join request.nu)
use ($LIB | path join roll.nu)
use ($LIB | path join ports.nu)
use ($LIB | path join report.nu)
use ($LIB | path join roles.nu)
use ($LIB | path join store.nu)

const NAME = "claude-manager"
const MECHANIC = "claude-mechanic"
const EDITOR = "claude-emacs"
const IMAGE = "claude"
const SCRATCH = "/tmp/claude-0"

def root []: nothing -> path { $env.HOME | path join claude }

def state []: nothing -> path { $env.HOME | path join .local share claude }

def config []: nothing -> path { $env.HOME | path join .config claude }

# Host config key cockpit.config: the directory of the user's own Emacs configuration, or null
def cockpit-config []: nothing -> any {
    let dir = hostcfg load | get -o cockpit.config
    if $dir == null { null } else { $dir | path expand --no-symlink }
}

# The containers, one role each, built from the role manifests (lib/roles.nu): `state` is the
# root of that role's own Claude state, `notify` and `wayland` say which host sockets it gets;
# what else its container sees is in `shape`.
def role-containers []: nothing -> record {
    roles seated | reduce -f {} {|r, acc|
        let access = $r.manifest.access? | default {}
        $acc | insert $r.role {
            name: $r.name, role: $r.role, state: (if $r.state == "" { state } else { state | path join $r.state })
            notify: ($access.notify? | default false), wayland: ($access.wayland? | default false), manifest: $r.manifest
        }
    }
}

# The primary role's container: the one a bare `homun` attaches to
def manager []: nothing -> record { role-containers | get $roles.PRIMARY }

# The cockpit: not a role (no session, no manifest). Its container runs the `emacs` service
# (container/emacs-container.sh) on the host's Wayland socket and is always started with the
# primary's. `editor` is its object and what CLAUDE_ROLE says inside it.
def editor []: nothing -> record {
    {name: $EDITOR, role: editor, state: (state | path join emacs), notify: true, wayland: true, cockpit: true, cmd: [sh /opt/homun/emacs-container.sh]}
}

# The containers next to the primary's, by their `homun <object>`: the cockpit, then every other role's
def side-roles []: nothing -> record { {editor: (editor)} | merge (role-containers | reject $roles.PRIMARY) }

# Left by `homun <role> enable` (host-only config, never mounted): while it exists a bare
# `homun` and `container restart` also take care of that role's container
def role-marker [role: string]: nothing -> path { roles marker $role }

def role-enabled [role: string]: nothing -> bool { $role == editor or (roles enabled $role) }

# The side roles that are enabled, in their fixed order
def enabled-roles []: nothing -> list<record> { side-roles | values | where {|r| role-enabled $r.role } }

# The host service (systemd/homun-host.service, bin/homun-host): the one user unit that answers the
# containers' requests, supervises the role containers and follows the pin, with this checkout
# and the tools' directories filled in, under ~/.config/systemd/user
const HOST_UNIT = "homun-host.service"

def unit-dir []: nothing -> path { ($env.XDG_CONFIG_HOME? | default ($env.HOME | path join .config)) | path join systemd user }

# PATH for a user unit: the directories of the tools this launch found, then the usual ones
def unit-path []: nothing -> string {
    let tools = [nu podman git zellij notify-send nix chafa identify] | each {|t| which $t | get -o 0.path } | compact | path dirname
    $tools | append [($env.HOME | path join .local bin) ($env.HOME | path join .nix-profile bin) /run/current-system/sw/bin /usr/local/bin /usr/bin /bin] | uniq | str join ":"
}

# Copy systemd/<file> into the unit directory with @WRAPPER@ and @PATH@ filled in
def unit-render [file: string] {
    mkdir (unit-dir)
    open --raw ($SCRIPT_DIR | path join systemd $file)
    | str replace -a "@WRAPPER@" $SCRIPT_DIR | str replace -a "@PATH@" (unit-path)
    | save -f (unit-dir | path join $file)
}

def host-unit-add [] {
    unit-render $HOST_UNIT
    systemctl --user daemon-reload
    systemctl --user enable $HOST_UNIT
    systemctl --user restart $HOST_UNIT
    log info $"($HOST_UNIT) answers the containers' requests, checks the role containers every 30 s and follows the pin; `homun host show` prints its state, `journalctl --user -u homun-host` its log"
}

def host-unit-del [] {
    systemctl --user disable --now $HOST_UNIT | complete | ignore
    rm -f (unit-dir | path join $HOST_UNIT)
    systemctl --user daemon-reload
}

def host-unit-show []: nothing -> record {
    let state = {|verb| systemctl --user $verb $HOST_UNIT | complete | get stdout | str trim }
    let file = unit-dir | path join $HOST_UNIT
    {
        unit: $HOST_UNIT
        installed: ($file | path exists)
        enabled: (do $state is-enabled)
        active: (do $state is-active)
        exec: (if ($file | path exists) { open --raw $file | lines | where ($it | str starts-with "ExecStart=") | first | str substring 10.. } else { null })
    }
}

# homun.service (systemd/homun.service): the one owner of the container and the Zellij session,
# outside any graphical session, so logging out of Niri ends only the clients. While its unit
# file exists, every launch that would create the session starts the unit instead and attaches.
const SERVICE_UNIT = "homun.service"

def service-file []: nothing -> path { unit-dir | path join $SERVICE_UNIT }

def service-installed []: nothing -> bool { service-file | path exists }

def service-add [] {
    unit-render $SERVICE_UNIT
    systemctl --user daemon-reload
    systemctl --user enable $SERVICE_UNIT
    log info $"($SERVICE_UNIT) installed and enabled; `systemctl --user start ($SERVICE_UNIT)` or a bare `homun` starts it"
}

def service-del [] {
    systemctl --user disable $SERVICE_UNIT | complete | ignore
    rm -f (service-file)
    systemctl --user daemon-reload
    log info $"($SERVICE_UNIT) removed; a running session stays until `homun session replace` or a logout"
}

def service-show []: nothing -> record {
    let state = {|verb| systemctl --user $verb $SERVICE_UNIT | complete | get stdout | str trim }
    let linger = loginctl show-user $env.USER --property=Linger --value | complete | get stdout | str trim
    {installed: (service-installed), enabled: (do $state is-enabled), active: (do $state is-active), linger: ($linger == yes)}
}

# Make sure the unit's session exists: start it, or restart it when its session is gone
# (RemainAfterExit keeps the unit active after a `session replace` or a crash killed the server)
def --env service-up [fresh: bool] {
    need zellij
    let exists = $NAME in (zellij-sessions)
    let verb = if $fresh or not $exists { "restart" } else { "start" }
    if $fresh and $exists { zellij kill-session $NAME | complete | ignore }
    let r = ^systemctl --user $verb $SERVICE_UNIT | complete
    if $r.exit_code != 0 {
        error make {msg: $"systemctl --user ($verb) ($SERVICE_UNIT) failed; see `journalctl --user -u ($SERVICE_UNIT)`\n($r.stderr | str trim)"}
    }
}

# The host's Wayland socket, hard-linked into a directory the container mounts at
# /run/claude-wayland.d (as wayland-0): a link, not a file mount, so a launch from a later
# graphical login can point it at that session's socket while the container keeps running.
# Same tmpfs as the socket (XDG_RUNTIME_DIR), so the hard link works.
def wayland-dir []: nothing -> path {
    let dir = runtime-dir | path join claude-wayland.d
    mkdir $dir
    $dir
}

def wayland-relink [] {
    let socket = wayland-socket
    if $socket == null { return }
    let dir = wayland-dir
    let target = $dir | path join wayland-0
    # already linked to this socket: renaming a hard link over itself is an error in nu's mv
    if ($target | path exists) and ((ls -l $target | get 0.inode) == (ls -l $socket | get 0.inode)) { return }
    let partial = $dir | path join $"wayland-0.($nu.pid)"
    let r = ^ln -f $socket $partial | complete
    if $r.exit_code != 0 { log warning $"cannot link the Wayland socket into ($dir): ($r.stderr | str trim)"; return }
    ^mv -f $partial $target
}

# Re-links the socket on every attach, then checks the running container sees that very inode:
# its bind mount of wayland-dir keeps pointing at the old directory if that was deleted and
# recreated (a reboot wipes the runtime dir), and then only a recreate fixes it.
def wayland-link [] {
    wayland-relink
    let host = wayland-dir | path join wayland-0
    if not ($host | path exists) { return }
    for name in [$NAME $EDITOR] {
        let seen = ^timeout 5 podman exec $name stat -L -c %i /run/claude-wayland.d/wayland-0 | complete
        if $seen.exit_code != 0 { continue }
        if ($seen.stdout | str trim) != (ls -l $host | get 0.inode | into string) {
            log warning $"($name) sees a stale Wayland socket \(its mount predates this login): run `homun container restart` to refresh it"
        }
    }
}

# Relays every new Manager container gets: the proxy service's port (container/services/proxy/env)
const DEFAULT_PORTS = ["8080"]

# Left by `just snap-enable`: a snapshot of ~/claude is taken before every container recreate
def snapshots-marker []: nothing -> path { config | path join snapshots }

const DEFAULT_CPUSET = ""

# The Manager's CPU pinning: `~/.config/claude/cpuset` holds the list (an empty file means no pinning), absent means no pinning unless the host config sets `cpuset`
def cpuset []: nothing -> string {
    let f = config | path join cpuset
    if ($f | path exists) { open --raw $f | str trim } else { hostcfg value cpuset $DEFAULT_CPUSET }
}

def gpu-enabled []: nothing -> bool { (homuncfg read gpu false) or (hostcfg value gpu false) }

def kvm-enabled []: nothing -> bool { (homuncfg read kvm false) or (hostcfg value kvm false) }

# Per-user scratch for files that only matter while the session is up
def runtime-dir []: nothing -> path {
    let xdg = $env.XDG_RUNTIME_DIR? | default ""
    if not ($xdg | is-empty) { return $xdg }
    let dir = $"/tmp/homun-(id -u)"
    mkdir $dir
    $dir
}

def device-set [device: string, want: bool] {
    let was = if $device == gpu { gpu-enabled } else { kvm-enabled }
    homuncfg write $device $want
    let state = if $want { 'on' } else { 'off' }
    let note = if $was == $want { $"($device) was already ($state)" } else { $"($device) is now ($state)" }
    print $"($note); applies at the next container recreate \(`homun container restart` or C-SPC u\)"
}

def host-only [] {
    if (hostcfg in-container) {
        log error 'This command only runs on the host, not inside a container'
        exit 1
    }
}

def --env ensure-notify-proxy []: nothing -> any {
    const UNIT = "claude-dbus-proxy"

    let runtime_dir = $env.XDG_RUNTIME_DIR?
    let bus = $env.DBUS_SESSION_BUS_ADDRESS?
    need xdg-dbus-proxy
    if $runtime_dir == null or $bus == null or (which xdg-dbus-proxy | is-empty) {
        log warning 'xdg-dbus-proxy or session bus unavailable, desktop notifications disabled'
        return null
    }

    # The socket lives in a directory of its own, and the container mounts the
    # directory: a mounted socket file would pin the inode of a proxy that died.
    let dir = $runtime_dir | path join homun-bus
    let socket = $dir | path join bus

    # Notifications: talk. The portal: see the name and call exactly
    # OpenURI on the portal object, so the container can ask the host to open a
    # URI with its default handler and nothing else (no OpenFile, no other
    # portal, no other method).
    let rules = [
        --talk=org.freedesktop.Notifications
        --see=org.freedesktop.portal.Desktop
        --call=org.freedesktop.portal.Desktop=org.freedesktop.portal.OpenURI.OpenURI@/org/freedesktop/portal/desktop
    ]

    # A unit started with an older filter must not outlive an update.
    let active = (do { systemctl --user is-active --quiet $UNIT } | complete).exit_code == 0
    let current = if $active { systemctl --user show $UNIT --property=ExecStart --value } else { "" }
    let stale = $active and (($rules | any {|rule| not ($current | str contains $rule) }) or not ($current | str contains $socket))
    if $stale {
        log debug $'Restarting ($UNIT), its filter or socket changed'
    }
    if $stale or not $active {
        log debug $'Starting ($UNIT)'
        # A dead or failed unit keeps its name: clear it so the start below cannot clash
        do { systemctl --user stop $UNIT } | complete | ignore
        do { systemctl --user reset-failed $UNIT } | complete | ignore
        mkdir $dir
        rm -f $socket
        systemd-run --user --quiet --collect --property=Restart=always --property=RestartSec=2 $'--unit=($UNIT)' xdg-dbus-proxy $bus $socket --filter ...$rules
        for _ in 1..50 {
            if ($socket | path exists) { break }
            sleep 100ms
        }
    }

    if ($socket | path exists) { $dir } else {
        log warning $'($UNIT) failed to create ($socket), desktop notifications disabled'
        null
    }
}

# The host's Wayland socket, for the frames of the `emacs` service (linked into
# wayland-dir by wayland-link; the service's env points WAYLAND_DISPLAY at the link)
def wayland-socket []: nothing -> any {
    let display = $env.WAYLAND_DISPLAY? | default ""
    let socket = if ($display | str starts-with "/") { $display } else { ($env.XDG_RUNTIME_DIR? | default "") | path join $display }
    if $display != "" and ($socket | str starts-with "/") and ($socket | path exists) { return $socket }
    log debug 'No Wayland socket (WAYLAND_DISPLAY/XDG_RUNTIME_DIR) to link for the emacs service'
    null
}

# The host's timezone name (Asia/Tokyo), from where /etc/localtime resolves to, or null. The file
# mount alone is not enough: the container's /etc/localtime is a symlink to Etc/UTC, so it replaces that
# zone's data, and programs that go by the zone's name (Node) stay in UTC.
def host_timezone []: nothing -> any {
    if not ('/etc/localtime' | path exists) { return null }
    let parts = ('/etc/localtime' | path expand | path split)
    let at = ($parts | enumerate | where item == zoneinfo | get -o 0.index)
    if $at == null or ($at + 1) >= ($parts | length) { null } else { $parts | skip ($at + 1) | str join '/' }
}

# What one container sees beyond its own Claude state, the things `plan` does not decide
# by itself: `workdir`, `paths` (project mounts, first), `gh` (a persisted ~/.config/gh), `extra`
# (mounts after the common ones), `env`, `volumes` (named volumes: the Nix store, Claude Code, the
# API key), `mkdirs` and `seed` for prepare. A role's come from its manifest's `session` and
# `access` (lib/roles.nu): all of ~/claude, and nothing more unless the manifest says so. The
# cockpit's are fixed here: all of ~/claude, no gh, every role's Claude state read-only with the
# credentials masked, the user's inboxes and secrets writable (~/claude/design/emacs-container/DESIGN.md).
def cal-inbox []: nothing -> path { root | path join .services mechanic cal-inbox }
# Where a cockpit on an older image asks for a recreate (`<epoch> restart [force]`; bin/claude-update-on-request)
def update-inbox []: nothing -> path { root | path join .services update emacs-request }
# The cockpit's part of the host service's request spool (bin/homun-host): what only the user may
# ask for (a recreate) is taken from here, so it is rw only in the editor
def host-inbox []: nothing -> path { root | path join .services host requests cockpit }
# The user's answers to the Manager's permission prompts (container/permission-hook.sh): rw only in the editor
def approve-answers []: nothing -> path { root | path join .services approve answers }
# The user's request for /compact in the Manager's TUI (container/compact-relay reads it): rw only in the editor
# Secrets the user types into their Emacs (the secret widget): OUTSIDE ~/claude, so the shared rw root never shows it.
# Mounted at a fixed path only in the editor (rw) and the Manager (ro); the mechanic and others get nothing.
def secrets-host []: nothing -> path { $env.HOME | path join .local share claude-secrets inbox }
const SECRETS_DST = "/run/claude-secrets"
def compact-inbox []: nothing -> path { root | path join .services compact emacs-request }

# The bus (container/homun-msg): bus/<role>/inbox.jsonl for every enabled role and bus/user/ for the
# user's own inbox. bus/<role>/user/<device>/ holds the user's words to that role: only the cockpit
# writes there, so every other container sees those directories read-only, the role's own too (see
# `shape`). bus/<role>/user-state/ is where that role's reader marks what it delivered: rw for the
# role, read-only to every other one.
def bus-root []: nothing -> path { root | path join .services bus }
def bus-roles []: nothing -> list<string> {
    [$roles.PRIMARY ...(side-roles | values | where {|r| role-enabled $r.role } | get role)] | uniq
}
def bus-dirs []: nothing -> list<path> {
    [(bus-root | path join user) ...(bus-roles | each {|r| [(bus-root | path join $r) (bus-root | path join $r user host) (bus-root | path join $r user-state)] } | flatten)]
}
def bus-user-dirs []: nothing -> list<path> { bus-roles | each {|r| bus-root | path join $r user } }
def bus-state-dirs []: nothing -> list<path> { bus-roles | each {|r| bus-root | path join $r user-state } }

# Another role's Claude state, read-only, with /dev/null bound over the credentials file so the
# OAuth secret stays hidden (podman binds a file over a file). Only once that role has one.
def state-mounts [src: path, dst: path]: nothing -> list<record> {
    if not ($src | path exists) { return [] }
    [{src: $src, dst: $dst, mode: ro} {src: /dev/null, dst: ($dst | path join .credentials.json), mode: ro}]
}

def shape [role: record]: nothing -> record {
    let home = $env.HOME
    let all = [{src: (root), dst: (root), mode: rw}]
    let shared = [(root) (root | path join .bare) (root | path join .services) (cal-inbox) (update-inbox) (host-inbox) (approve-answers) (compact-inbox)]
    let volumes = [
        --volume=claude-nix:/nix
        $'--volume=claude-nix-cache:($home)/.cache/nix'
        $'--volume=claude-code:($home)/.local/share/claude'
        $'--volume=claude-code-bin:($home)/.local/bin'
    ]
    let others = role-containers
    if ($role.cockpit? | default false) {
        # The host's own Emacs configuration, the cockpit's flavour (container/services/emacs/run): at
        # the same path inside, mounted read-only when it is not under ~/claude already
        let config = cockpit-config
        return {
            workdir: (root), paths: $all, gh: false, mkdirs: [...$shared ...(bus-dirs) (secrets-host)], own_claude: false
            env: [--env $'CLAUDE_ROLE=($role.role)' ...(if $config == null { [] } else { [--env $'HOMUN_COCKPIT_CONFIG=($config)'] })]
            extra: [
                ...(if $config == null or not ($config | path exists) or ($config | str starts-with $'(root)/') { [] } else { [{src: $config, dst: $config, mode: ro}] })
                # The user's inboxes and secrets stay writable here and nowhere else
                {src: (secrets-host), dst: $SECRETS_DST, mode: rw}
                # Every role's Claude state, for their transcripts: the primary's as the cockpit's own
                # ~/.claude (always), the others' at /mnt/<key>-claude
                {src: ($others | get $roles.PRIMARY | get state | path join claude), dst: ($home | path join .claude), mode: ro}
                {src: /dev/null, dst: ($home | path join .claude .credentials.json), mode: ro}
                ...($others | reject $roles.PRIMARY | values | each {|o| state-mounts ($o.state | path join claude) $"/mnt/($o.role)-claude" } | flatten)
            ]
            volumes: $volumes
            seed: null
        }
    }

    let access = $role.manifest.access? | default {}
    let session = $role.manifest.session? | default {}
    let at = {|p| $p | str replace -r '^@root' (root) | str replace -r '^@home' $home | str replace -r '^@state' $role.state }
    let secrets = $access.secrets? | default null
    # The user's words and requests (the mechanic's inbox, update, approve, compact): only the cockpit
    # keeps them rw; every role overmounts them ro
    let inbox_ro = [(cal-inbox) (update-inbox) (host-inbox) (approve-answers) (compact-inbox)] | each {|d| {src: $d, dst: $d, mode: ro} }
    let own_state = bus-root | path join $role.role user-state
    let bus_ro = [...(bus-user-dirs) ...(bus-state-dirs | where {|d| $d != $own_state })] | each {|d| {src: $d, dst: $d, mode: ro} }
    {
        workdir: (do $at ($session.workdir? | default "@root")), paths: $all, gh: ($access.gh? | default false)
        mkdirs: [...$shared ...(bus-dirs) ...(if $secrets == null { [] } else { [(secrets-host)] })]
        # The primary's container is not told its role: it is what CLAUDE_ROLE defaults to inside
        env: (if $role.role == $roles.PRIMARY { [] } else { [--env $'CLAUDE_ROLE=($role.role)'] })
        extra: [
            ...$inbox_ro
            # The user's words on the bus, written by the cockpit alone, and other roles' claim markers
            ...$bus_ro
            ...(if $secrets == null { [] } else { [{src: (secrets-host), dst: $SECRETS_DST, mode: $secrets}] })
            ...($access.read_state_of? | default [] | each {|e|
                let key = if ($e | describe) == string { $e } else { $e.role }
                let src = $others | get $key | get state | path join claude
                state-mounts $src (if ($e | describe) != string and $e.at? == "@host" { $src } else { $"/mnt/($key)-claude" })
            } | flatten)
        ]
        volumes: [...$volumes ...($access.volumes? | default [] | each {|v| $'--volume=($v.name):(do $at $v.at)' })]
        seed: (if $session.seed? == null { null } else { {src: ($SCRIPT_DIR | path join $session.seed.src), dst: (do $at $session.seed.dst)} })
    }
}

# The podman arguments and host preparation for one role's container; `shape` holds what
# differs between the roles.
def plan [role: record, notify_socket: any, wayland_socket: any]: nothing -> record {
    let state = $role.state
    let shape = shape $role

    # Claude's state, persisted on the host; `kind` is what prepare creates so podman does not guess
    let state_mounts = [
        ...(if ($shape.own_claude? | default true) {[
            {src: ($state | path join claude), dst: ($env.HOME | path join .claude), kind: dir}
            {src: ($state | path join claude.json), dst: ($env.HOME | path join .claude.json), kind: file}
        ]} else { [] })
        ...(if $shape.gh { [{src: ($state | path join gh), dst: ($env.HOME | path join .config gh), kind: dir}] } else { [] })
        # A directory, not a file: git writes config via .lock + rename, which fails (EBUSY) on a file bind mount.
        # prep touches config inside it, since --global only uses this file instead of ~/.gitconfig when it exists.
        {src: ($state | path join git), dst: ($env.HOME | path join .config git), kind: dir}
        {src: ($state | path join scratch), dst: $SCRATCH, kind: dir}
    ]

    let mounts = [
        ...$shape.paths
        ...($state_mounts | each {|m| {src: $m.src, dst: $m.dst, mode: rw} })

        # Over the image's copy, so edits to the checkout's scripts apply without a rebuild. Only when the
        # source is really there: a missing directory would be mounted as an empty one, hiding the image's copy.
        ...(if ($SCRIPT_DIR | path join container entrypoint.sh | path exists) {
            [{src: ($SCRIPT_DIR | path join container), dst: /opt/homun, mode: ro}]
        } else { [] })

        # The agent identity (name, pronouns, emoji), when the user has one; else the image's container/agent.json
        ...(if ($env.HOME | path join .config claude agent.json | path exists) {
            [{src: ($env.HOME | path join .config claude agent.json), dst: /run/claude-agent.json, mode: ro}]
        } else { [] })

        # The host config, read by container tools too (the emacs build)
        ...(if (hostcfg file | path exists) { [{src: (hostcfg file), dst: /run/claude-config.json, mode: ro}] } else { [] })

        # The host-local roles (lib/roles.nu): identities and new roles, never in the repo
        ...(if (roles dir | path exists) { [{src: (roles dir), dst: $roles.MOUNT, mode: ro}] } else { [] })

        # The host's timezone, so dates inside (and in the status line's usage samples) read in local time.
        # Resolved first: on NixOS it is a symlink into the store, and the container has no store at that path.
        ...(if ('/etc/localtime' | path exists) { [{src: ('/etc/localtime' | path expand), dst: /etc/localtime, mode: ro}] } else { [] })

        ...(if $notify_socket == null { [] } else { [{src: $notify_socket, dst: /run/homun-bus, mode: rw}] })
        ...(if $wayland_socket == null { [] } else { [{src: $wayland_socket, dst: /run/claude-wayland.d, mode: rw}] })

        ...$shape.extra
    ]

    let args = [
        --name=($role.name)
        --hostname=($role.name)
        --workdir=($shape.workdir)

        --env $'PS1=(ansi magenta_bold)\h(ansi reset)$ '
        --env ENABLE_LSP_TOOL=1
        --env COLORTERM=truecolor
        --env HOME=($env.HOME)
        ...$shape.env
        ...(host_timezone | if $in == null { [] } else { [--env $'TZ=($in)'] })
        ...(if $notify_socket == null { [] } else { [--env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/homun-bus/bus] })

        ...($mounts | each {|m| $'--volume=($m.src):($m.dst):($m.mode)' })
        ...$shape.volumes

        ...(if (gpu-enabled) { [--device /dev/dri --group-add keep-groups $'--security-opt=seccomp=($SCRIPT_DIR | path join seccomp.json)'] } else { [] })
        ...(if (kvm-enabled) { [--device /dev/kvm] | append (if (gpu-enabled) { [] } else { [--group-add keep-groups] }) } else { [] })

        --security-opt=unmask=/proc/*

        ...(if ($role.manifest?.access?.cpuset? | default false) and (cpuset) != "" { [$'--cpuset-cpus=(cpuset)'] } else { [] })
    ]

    let prep = {
        mkdirs: [...$shape.mkdirs ...($state_mounts | where kind == dir | get src)]
        touches: [...($state_mounts | where kind == file | get src) ($state | path join git config)]
        # The Manager's operating guide, or a side role's permissions; a copy that exists is never overwritten
        seed: $shape.seed
    }

    {name: $role.name, role: $role.role, args: $args, prep: $prep, cmd: ($role.cmd? | default []), health: (health $role), live: ($role.manifest?.access?.live_mounts? | default false)}
}

# Container-level resilience, kept out of `args` so it does not count as a change of plan
# (plan-hash): podman restarts a role's container that exits non-zero, and a health check (the
# manifest's `health`; the cockpit's daemon answering on its socket) tells bin/claude-supervise
# when it is alive but not working. The image has no pgrep (no procps), so the commands read
# /proc directly. A role with `restart: none` has no restart policy: an exit 75 means an update
# was requested and claude-attach must see the stopped container.
def health [role: record]: nothing -> list<string> {
    let cmd = if ($role.cockpit? | default false) {
        $"/nix/var/nix/profiles/emacs/bin/emacsclient -s (root)/.services/emacs/socket -e t"
    } else {
        $role.manifest.health? | default "" | str replace --all '@root' (root)
    }
    [
        ...(if ($role.manifest?.restart? | default "") == none { [] } else { [--restart=on-failure:5] })
        ...(if $cmd == "" { [] } else { [--health-cmd=($cmd) --health-interval=30s --health-timeout=10s --health-retries=3 --health-start-period=10m] })
    ]
}

def prepare [prep: record] {
    for d in $prep.mkdirs {
        mkdir $d
        # The user's secrets: the directory and its parent are for them alone
        if $d == (secrets-host) { ^chmod 700 $d ($d | path dirname) }
    }
    for f in $prep.touches { touch $f }

    if $prep.seed != null and not ($prep.seed.dst | path exists) {
        log info $'Seeding ($prep.seed.dst)'
        open --raw $prep.seed.src | str replace --all '@HOME@' $env.HOME | save $prep.seed.dst
    }
}

def is-running [name: string = $NAME]: nothing -> bool {
    (podman ps --filter $'name=^($name)$' --format '{{.Names}}' | str trim) == $name
}

# Left by an explicit `homun ... stop`, removed by any start: bin/claude-supervise leaves a
# container its user stopped on purpose alone
def stopped-marker [name: string]: nothing -> path { config | path join $"stopped-($name)" }

def stop-on-purpose [name: string = $NAME] {
    mkdir (config)
    touch (stopped-marker $name)
    stop-container $name
}

def stop-container [name: string = $NAME] {
    if not (is-running $name) { return }

    log info $"Stopping container ($name)"
    podman stop $name | ignore
    remove-container $name
}

# The container is started without --rm so claude-attach can read its exit code
# after it ends (podman attach returns 0 whatever that code was); remove what is
# left of it before starting another under the same name
def remove-container [name: string = $NAME] {
    podman rm --ignore $name | complete | ignore
}

const PLAN_LABEL = "claude.plan"

# A hash of the planned podman arguments, stored on the container as a label: a running container
# whose label differs (or has none) was started with other mounts or env than the plan now says
def plan-hash [plan: record]: nothing -> string {
    $plan.args | to json --raw | hash sha256 | str substring 0..15
}

# The notification socket's directory a start would mount, without starting its proxy (ensure-notify-proxy does that)
def planned-notify-socket []: nothing -> any {
    if $env.XDG_RUNTIME_DIR? == null or $env.DBUS_SESSION_BUS_ADDRESS? == null { null } else { $env.XDG_RUNTIME_DIR | path join homun-bus }
}

# `homun container plan [<key>]`: one role's plan as plain lines in a fixed order, to keep and diff
# across changes of the launcher. Starts nothing; `hash` is what the container's label would carry.
def plan-text [key: string]: nothing -> string {
    let all = {($roles.PRIMARY): (manager)} | merge (side-roles)
    if $key not-in ($all | columns) {
        error make {msg: $"unknown role '($key)'; one of: ($all | columns | str join ', ')"}
    }
    let plan = side-plan ($all | get $key) (planned-notify-socket)
    [
        $"# homun container plan ($key)"
        $"name ($plan.name)"
        $"role ($plan.role)"
        $"hash (plan-hash $plan)"
        "[args]" ...$plan.args
        "[cmd]" ...$plan.cmd
        "[health]" ...$plan.health
        "[prep]"
        ...($plan.prep.mkdirs | each {|d| $"mkdir ($d)" })
        ...($plan.prep.touches | each {|f| $"touch ($f)" })
        ...(if $plan.prep.seed == null { [] } else { [$"seed ($plan.prep.seed.src) -> ($plan.prep.seed.dst)"] })
    ] | str join "\n"
}

def plan-changed [plan: record]: nothing -> bool {
    let r = ^podman inspect --format $'{{index .Config.Labels "($PLAN_LABEL)"}}' $plan.name | complete
    $r.exit_code != 0 or ($r.stdout | str trim) != (plan-hash $plan)
}

# A new machine has no image yet: build it once instead of failing to start
def ensure-image [] {
    if (^podman image exists $IMAGE | complete).exit_code == 0 { return }
    print $"image ($IMAGE) does not exist yet; building it"
    need just
    just -f ($SCRIPT_DIR | path join justfile) build
}

def --env ensure-container [plan: record] {
    let name = $plan.name
    rm -f (stopped-marker $name)
    if (is-running $name) {
        log debug $'Container ($name) is already running'
        return
    }

    log info $'Starting ($name) in the background'
    ensure-image
    prepare $plan.prep
    remove-container $name

    try {
        # HOMUN_IMAGE: one role recreated on another image (its previous one: lib/roll.nu)
        podman run --detach --interactive --tty $"--label=($PLAN_LABEL)=(plan-hash $plan)" ...$plan.health ...$plan.args ($env.HOMUN_IMAGE? | default $IMAGE) ...$plan.cmd | ignore
    } catch {|err|
        log debug $"podman run failed \(possibly already started concurrently\): ($err.msg)"
    }

    if not (is-running $name) {
        error make {msg: $'Failed to start container ($name)'}
    }

    # Ad-hoc mounts and relays last as long as the container: a new one forgets them.
    # Only the declared defaults come back, and only for the container they target.
    if $plan.live {
        mounts reset
        ports reset
        # The host config's declared relays come back (apply); a default it declares keeps its scope
        let declared = ports list | get spec
        for port in $DEFAULT_PORTS {
            if $"($port):($port)/tcp" not-in $declared {
                ports open $name $port container host
            }
        }
        ports apply $name
    }
}

# Checks and preparation for a restart, before the old container is stopped
def preflight [plan: record] {
    ensure-image
    prepare $plan.prep
    for arg in $plan.args {
        # --volume=<host path>:<container path>:<mode>; named volumes have no slash
        let src = $arg | parse --regex '^--volume=(/[^:]*):' | get -o 0.capture0
        if $src != null and not ($src | path exists) {
            error make {msg: $"mount source ($src) does not exist"}
        }
    }
    if $plan.live {
        mounts check
        ports check
    }
}

# A container's plan: the display and the notification socket only where it has them
def side-plan [role: record, notify_socket: any]: nothing -> record {
    plan $role (if $role.notify { $notify_socket } else { null }) (if ($role.wayland? | default false) { wayland-dir } else { null })
}

def --env side-notify [role: record]: nothing -> any { if $role.notify { ensure-notify-proxy } else { null } }

# The container a pane role's session runs in (`seat: {kind: pane, in: <role>}`), or null when
# the key is not such a role
def pane-role [key: any]: nothing -> any {
    let seat = if $key == null { {} } else { roles load | get -o $key | default {} | get -o seat | default {} }
    if ($seat.kind? | default "") != pane { return null }
    roles seated | where role == ($seat.in? | default $roles.PRIMARY) | get -o 0.name
}

# The verbs every side role's object shares (`homun mechanic ...`)
const SIDE_VERBS = [start stop restart attach show enable disable]

def --env side-verb [role: record, verb: string, rest: list<string>] {
    let name = $role.name
    match $verb {
        start => { no-args $rest; ensure-container (side-plan $role (side-notify $role)) }
        stop => { no-args $rest; stop-on-purpose $name }
        restart => {
            no-args $rest
            let plan = side-plan $role (side-notify $role)
            preflight $plan
            stop-container $name
            ensure-container $plan
        }
        attach => {
            let via = if ($role.cockpit? | default false) { no-args $rest; "shell" } else { (kw $rest {via: [claude shell]}).via }
            ensure-container (side-plan $role (side-notify $role))
            if $via == shell { exec podman exec -it $name /usr/local/bin/nu }
            exec ($SCRIPT_DIR | path join bin claude-attach) --no-update $name
        }
        show => {
            no-args $rest
            print ({name: $name, running: (is-running $name), enabled: (role-enabled $role.role)})
        }
        enable => {
            host-only
            no-args $rest
            mkdir (config)
            touch (role-marker $role.role)
            log info $"($name) now starts with the Manager's container and follows its restarts; run `homun ($role.role) start` to start it now"
        }
        disable => {
            host-only
            no-args $rest
            rm -f (role-marker $role.role)
            log info $"($name) no longer starts with the Manager's container; `homun ($role.role) stop` stops a running one"
        }
    }
}

# With snapshots enabled (`just snap-enable`), take one before the old container is stopped; a
# failure aborts the restart before this function stops anything, like a failed preflight; `sudo -n`
# in the recipe means a missing sudoers rule fails at once instead of waiting for a password
def --env snapshot-before-recreate [] {
    if not (snapshots-marker | path exists) { return }
    log info "Snapshotting ~/claude/.bare and .services before the recreate"
    need just
    let r = ^just -f ($SCRIPT_DIR | path join justfile) snap pre-recreate | complete
    if $r.exit_code != 0 {
        let why = $r.stderr | str trim | lines | last 1 | append "" | first
        error make {msg: $"snapshot of .bare/.services failed, so the container was not recreated: ($why)\nThis needs a passwordless sudoers rule for `bcachefs subvolume snapshot` (see the comment block in the justfile), or remove ~/.config/claude/snapshots to turn snapshots off."}
    }
}

# The Zellij sessions that are alive (not EXITED ones waiting to be resurrected)
def zellij-sessions []: nothing -> list<string> {
    do { zellij list-sessions --no-formatting } | complete | get stdout | lines
    | where not ($it | str contains EXITED) | each { split row " " | first } | where $it != ""
}

# What bin/claude-update and the session's panes need to find this checkout and the Manager
def --env update-env [] {
    $env.CLAUDE_CONTAINER = $NAME
    $env.HOMUN_DIR = root
    $env.HOMUN_ARGS = [] | to json --raw
    $env.HOMUN_UPDATING = runtime-dir | path join $"homun-($NAME).updating"
}

# The environment the session's panes inherit, and its rendered layout; returns {config, layout}
def --env zellij-setup []: nothing -> record {
    update-env
    $env.PATH = $env.PATH | prepend ($SCRIPT_DIR | path join bin)

    # The layout is copied next to its final name and renamed into place, so a concurrent
    # launch never reads a half-written file.
    let config = $SCRIPT_DIR | path join zellij config.kdl
    let layout = runtime-dir | path join $"homun-($NAME).layout.kdl"
    let partial = $"($layout).($nu.pid)"
    open --raw ($SCRIPT_DIR | path join zellij layout.kdl) | save -f $partial
    mv -f $partial $layout

    cd (root)
    # Panes run c/run.nu again; let them fetch the tools on their own if the store path is gone
    hide-env -i HOMUN_FLAKE
    {config: $config, layout: $layout}
}

# `homun service run`, homun.service's ExecStart: the container, then the session as a detached
# server in the unit's cgroup (it outlives this oneshot through RemainAfterExit)
def --env service-run [] {
    host-only
    up
    need zellij
    let z = zellij-setup
    if $NAME in (zellij-sessions) { log info $"Zellij session '($NAME)' already runs"; return }
    zellij delete-session $NAME | complete | ignore
    log info $"Creating Zellij session '($NAME)' in the background"
    ^zellij --config $z.config attach --create-background $NAME options --default-layout $z.layout
    tab-keeper $z.layout
}

# The tab keeper (bin/claude-tab-keeper): re-creates a standing tab that was closed;
# one per session through flock, ending with the session
def tab-keeper [layout: path] {
    let bin = $SCRIPT_DIR | path join bin claude-tab-keeper
    if (which setsid flock | length) != 2 { return }
    let lock = ($env.XDG_RUNTIME_DIR? | default "/tmp") | path join $"claude-tab-keeper-($NAME).lock"
    try { ^setsid -f flock -n $lock nu $bin $NAME $layout o+e>> ($lock | str replace '.lock' '.log') }
}

def --env attach-zellij [fresh: bool] {
    need zellij
    if (service-installed) {
        # The unit owns the one server; this only adds a client to it
        service-up $fresh
        let z = zellij-setup
        log info $"Attaching to Zellij session '($NAME)' of ($SERVICE_UNIT)"
        tab-keeper $z.layout
        # A session that ends without C-SPC q (a crash, a kill) is started again and reattached
        # while the container runs: the unit restarts the server, the container is not touched
        let quit = runtime-dir | path join $"homun-($NAME).quit"
        rm -f $quit
        # No limit: the wait doubles from 2 s to 30 s while it keeps ending, back to 2 s after a
        # session that lived 5 minutes
        mut wait = 2sec
        loop {
            let began = date now
            ^zellij --config $z.config attach $NAME
            let old = $quit | path dirname | path join ($quit | path basename | str replace homun- claude-wrapper-)
            if ($quit | path exists) or ($old | path exists) { rm -f $quit $old; break }
            if $NAME in (zellij-sessions) { break }  # detached: the session lives on
            if ((date now) - $began) > 5min { $wait = 2sec }
            log warning $"Zellij session '($NAME)' ended; starting it again in ($wait)"
            sleep $wait
            $wait = [($wait * 2) 30sec] | math min
            service-up false
            tab-keeper $z.layout
        }
        return
    }

    let z = zellij-setup
    let args = [
        --config $z.config
        options
        --default-layout $z.layout
        --session-name $NAME
        --attach-to-session true
    ]

    mut existing = zellij-sessions
    if $fresh and $NAME in $existing {
        log info $"Ending Zellij session '($NAME)' to start a fresh one"
        zellij kill-session $NAME
        zellij delete-session $NAME | complete | ignore
        $existing = $existing | where $it != $NAME
    }

    if $NAME in $existing {
        log info $"Attaching to existing Zellij session '($NAME)'; run `homun session replace` for a fresh one \(e.g. after layout changes)"
    } else {
        log info $"Creating Zellij session '($NAME)'"
    }

    tab-keeper $z.layout
    exec zellij ...$args
}

# Fail with the usage line unless rest holds min to max words (max null: no limit)
def arity [rest: list<string>, min: int, max: any, usage: string] {
    let n = $rest | length
    if $n < $min or ($max != null and $n > $max) { error make {msg: $usage} }
}

def no-args [rest: list<string>] {
    if ($rest | is-not-empty) { error make {msg: $"unexpected argument '($rest | first)'; `homun <command> --help` says what it takes"} }
}

# Positional `<keyword> <value>` pairs after a command's words, like `ip addr add ... scope link`:
# `accepted` maps each keyword to its allowed values, the first the default (an empty list takes
# any value, default null); returns keyword -> value
def kw [args: list<string>, accepted: record]: nothing -> record {
    mut result = $accepted | items {|key, values| {($key): ($values | get -o 0)} } | into record
    mut rest = $args
    while ($rest | is-not-empty) {
        let key = $rest | first
        let values = $accepted | get -o $key
        if $values == null { error make {msg: $"unknown option '($key)', expected ($accepted | items {|key, values| $"[($key) (if ($values | is-empty) { '<value>' } else { $values | str join '|' })]" } | str join ' ')"} }
        let value = $rest | get -o 1
        if $value == null { error make {msg: $"'($key)' needs a value: ($values | str join '|')"} }
        if ($values | is-not-empty) and $value not-in $values {
            error make {msg: $"'($key)' must be one of ($values | str join '|'), not '($value)'"}
        }
        $result = $result | merge {($key): $value}
        $rest = $rest | skip 2
    }
    $result
}

# The Manager's container, and each enabled side role's too
def --env up [] {
    let notify = ensure-notify-proxy
    wayland-link
    # The Emacs container first and on its own: neither waits for the other, a failed start of one
    # does not stop the other
    try { ensure-container (side-plan (editor) $notify) } catch {|e| log error $"claude-emacs: ($e.msg)" }
    ensure-container (side-plan (manager) $notify)
    for role in (enabled-roles | where role != editor) { ensure-container (side-plan $role $notify) }
}

# Before attaching: with homun.service the unit starts the container (systemctl in
# attach-zellij), so a launch only re-links this login's Wayland socket; without it, `up`
def --env launch-up [] {
    if (service-installed) { wayland-link } else { up }
}


# `homun cockpit device add <name> [secrets] [approve] [readonly] [alarms] | del <name> | show`: the
# remote cockpit's device keys, devices/<name>.json in the cockpit-gateway service (only the key's
# SHA-256 is kept; the key is printed once). The first device enables and starts the gateway in the
# cockpit's container, deleting the last one stops it; the gateway reads the files on every request.
def cockpit-device [rest: list<string>] {
    let dir = root | path join .services cockpit-gateway
    let devices = $dir | path join devices
    let words = [secrets approve readonly alarms]
    match ($rest | get -o 0 | default help) {
        show => {
            if not ($devices | path exists) { return }
            ls $devices | where name =~ '\.json$' | each {|f| open $f.name } | each {|d|
                {name: $d.name, created: ($d.created * 1_000_000_000 | into datetime), perms: ($words | where {|w| $d | get -o $w | default false } | str join ",")}
            } | print
        }
        add => {
            arity $rest 2 6 $"usage: homun cockpit device add <name> [($words | str join '] [')]"
            let name = $rest.1
            if $name !~ '^[a-z0-9][a-z0-9-]{0,31}$' or $name == host { error make {msg: "a device name is [a-z0-9-], at most 32, and not host"} }
            let perms = $rest | skip 2
            let bad = $perms | where $it not-in $words
            if ($bad | is-not-empty) { error make {msg: $"unknown permission ($bad | str join ', '): one of ($words | str join ', ')"} }
            let file = $devices | path join $"($name).json"
            if ($file | path exists) { error make {msg: $"device ($name) exists: del it first"} }
            mkdir $devices
            let key = random binary 32 | encode hex | str lowercase
            let created = (date now | into int) // 1_000_000_000
            let flags = $words | each {|w| [$w ($w in $perms)] } | into record
            let device = {name: $name, sha256: ($key | hash sha256), created: $created} | merge $flags
            $device | to json -r | save -f $"($file).tmp"
            chmod 600 $"($file).tmp"
            mv -f $"($file).tmp" $file
            rm -f ($dir | path join disabled)
            try { if (is-running $EDITOR) { podman exec $EDITOR claude-services start cockpit-gateway | complete | ignore } }
            print $"device ($name) added; its key, shown once \(the remote Emacs's claude-remote-key\):"
            print $key
            print "" (cockpit-snippet $name $key)
        }
        del => {
            arity $rest 2 2 "usage: homun cockpit device del <name>"
            let file = $devices | path join $"($rest.1).json"
            if not ($file | path exists) { error make {msg: $"no device ($rest.1)"} }
            rm $file
            if (glob ($devices | path join "*.json") | is-empty) {
                touch ($dir | path join disabled)
                try { if (is-running $EDITOR) { podman exec $EDITOR claude-services stop cockpit-gateway | complete | ignore } }
            }
        }
        _ => { show-help cockpit }
    }
}

# The init.el block (container/emacs/homun-init.el) that starts the remote cockpit with this device's
# key: it fetches the proxy's root certificate once, checks it against the pin printed here, and
# fetches the client files from the gateway over TLS that trusts only that certificate.
def cockpit-snippet [name: string, key: string] {
    let proxy = root | path join .services proxy
    let host = try { open ($proxy | path join hosts) | lines | where $it =~ '^[A-Za-z0-9._-]+$' | first } catch { "<host>" }
    let pin = try {
        open --raw ($proxy | path join root.crt) | lines | where not ($it | str starts-with "-----") | str join | decode base64 | hash sha256
    } catch { "<no root.crt yet: start the proxy, then device del + add>" }
    let conf = $"\(setq homun-conf '\(:url \"https://($host):8443/cockpit-gateway/\" :key \"($key)\" :pin \"($pin)\" :device \"($name)\"\)\)"
    open --raw ($SELF | path dirname | path join container emacs homun-init.el) | str replace "(setq homun-conf nil)" $conf
}

# `homun share <file> [for <duration>] | list | del <token>`: stage the file under ~/claude/.services/edge/share/,
# let the edge copy it into the page host as a download (claude-edge publish file), then drop the staging copy.
def share-cmd [rest: list<string>] {
    let edge = [podman exec $NAME python3 -I /opt/homun/claude-edge]
    let word = $rest | get -o 0 | default help
    if $word == help { return (show-help share) }
    if $word == list {
        let rows = ^$edge.0 ...($edge | skip 1) published | lines | split column "\t" token left name | where name =~ '^file:'
        return (print ($rows | update name {|r| $r.name | str substring 5.. } | rename token expires file))
    }
    if $word == del {
        arity $rest 2 2 "usage: homun share del <token>"
        ^$edge.0 ...($edge | skip 1) unpublish $rest.1
        return
    }
    let opts = kw ($rest | skip 1) {for: []}
    let file = $rest.0 | path expand
    if ($file | path type) != file { error make {msg: $"($file) is not a file"} }
    let stage = root | path join .services edge share (random chars --length 16)
    mkdir $stage
    try { ^chmod 755 ($stage | path dirname) $stage }
    let copy = $stage | path join ($file | path basename)
    cp $file $copy
    let dur = $opts.for | default 24h
    let out = ^$edge.0 ...($edge | skip 1) publish file $copy for $dur | complete
    rm -rf $stage
    if $out.exit_code != 0 { error make {msg: ($out.stderr | str trim)} }
    let url = $out.stdout | lines | first
    print $url
    print $"expires in ($dur); remove earlier with homun share del <token> \(homun share list\)"
    if (which wl-copy | is-not-empty) and ($env.WAYLAND_DISPLAY? | is-not-empty) {
        try { $url | ^wl-copy e>| ignore; print "link copied" }
    }
}

# `homun send <file> [args...]`: claude-send in the foreground (C-c ends the send). A file under ~/claude is already
# visible in the container at the same path; any other is hard-linked (else copied) under ~/claude/.services/shares/
# for the duration (cheaper and tidier than a lingering mount). claude-send starts the send service itself.
def send-cmd [rest: list<string>] {
    let word = $rest | get -o 0 | default help
    if $word in [help list stop] {
        if $word == help { return (show-help send) }
        exec podman exec -it $NAME python3 -I /opt/homun/claude-send ...$rest
    }
    let file = $word | path expand
    if ($file | path type) != file { error make {msg: $"($file) is not a file"} }
    let staged = not ($file | str starts-with ((root) + "/"))
    mut path = $file
    let stage = root | path join .services shares (["stage-" (random chars --length 12)] | str join)
    if $staged {
        mkdir $stage
        try { ^chmod 755 ($stage | path dirname) $stage }
        $path = $stage | path join ($file | path basename)
        if (^ln $file $path | complete).exit_code != 0 { cp $file $path }
    }
    let args = ["wait"] ++ ($rest | skip 1)
    let code = try { ^podman exec -it $NAME python3 -I /opt/homun/claude-send $path ...$args; 0 } catch {|e| $e.exit_code? | default 1 }
    if $staged { rm -rf $stage }
    if $code != 0 { exit $code }
}

# `homun cmd` and `homun clip`: list ~/claude/.bin, or run / copy one of its scripts.
def bin-cmd [mode: string, rest: list<string>] {
    let bin = root | path join .bin
    let name = $rest | get -o 0 | default show
    if $name == show {
        arity $rest 0 1 $"usage: homun ($mode | str replace run cmd) [show]"
        if ($bin | path exists) {
            print (ls $bin | where type == file | get name | path basename | sort | each {|n|
                let desc = open --raw ($bin | path join $n) | lines | skip 1 | where $it =~ '^\s*#' | get -o 0 | default "" | str replace -r '^\s*#\s*' ''
                $"($n)  ($desc)" | str trim
            } | str join "\n")
        }
        return
    }
    if $name == help { return (show-help ($mode | str replace run cmd)) }
    let file = $bin | path join $name
    if $name != ($name | path basename) or $name in [. ..] or not ($file | path exists) or ($file | path type) != file or (do { ^test -x $file } | complete | get exit_code) != 0 {
        error make {msg: $"no executable '($name)' in ($bin); `homun ($mode | str replace run cmd) show` lists them"}
    }
    if $mode == clip {
        if (which wl-copy | is-empty) { error make {msg: "wl-copy not found (nixpkgs wl-clipboard)"} }
        let remote = open --raw $file | parse --regex "(?m)^let remote = '(?<cmd>[^']*)'" | get -o 0.cmd
        let line = $remote | default ([$file ...($rest | skip 1)] | str join " ")
        print $line
        let key = input --numchar 1 "copy? [y/N] "
        print ""
        if ($key | str lowercase) != "y" { return }
        $line | ^wl-copy
        return (print $"copied: ($line)")
    }
    if (which bat | is-not-empty) { ^bat --paging never $file } else { print (open --raw $file) }
    let key = input --numchar 1 $"run ($name)? [y/N] "
    print ""
    if ($key | str lowercase) != "y" { return }
    exec $file ...($rest | skip 1)
}

# Stop the given roles' containers and start them again. One role failing to start must not leave
# the others down: start every one, then report
def recreate-wave [plans: list<record>] {
    for p in ($plans | reverse) { stop-container $p.name }
    mut failed = []
    for p in $plans {
        let err = try { ensure-container $p; null } catch {|e| $e.msg }
        if $err != null { log error $err; $failed ++= [$p.name] }
    }
    if ($failed | is-not-empty) { error make {msg: $"failed to start: ($failed | str join ', ')"} }
}

# Run a command's body the way every command runs: no stray XOFF, never as root, and a failure
# printed as `homun: <msg>` plus its hint lines, exit 1 (HOMUN_DEBUG=1 keeps the full trace)
def --env cli [body: closure] {
    # A paused terminal (C-s, XOFF) blocks every print until C-q
    if (is-terminal --stdin) { try { ^stty -ixon } }
    try {
        # Rootless by design: as root it would make root-owned state and a rootful container
        if (^id -u | str trim) == "0" and not ("/run/.containerenv" | path exists) {
            error make {msg: "homun must not run as root; run it as your own user"}
        }
        do --env $body
    } catch {|err| fail $err }
}

# Print another command's generated help (`homun cockpit` words with no verb)
def show-help [...path: string] { print (^$nu.current-exe $SELF ...$path --help) }

# Commands that end or cut running work are refused while it is ongoing (lib/busy.nu) unless the
# words hold `force`, `-f` or `--force`; returns the words without it
def guarded [rest: list<string>, cmd: string]: nothing -> list<string> {
    let force = $rest | any {|a| $a in [force -f --force] }
    busy guard $force $NAME ($"homun ($cmd) ($rest | where {|a| $a not-in [force -f --force] } | str join ' ')" | str trim)
    $rest | where {|a| $a not-in [force -f --force] }
}

# The launcher: no words attach to the Zellij session (starting the containers first), or run a
# role's own verbs as `homun <role> <verb>` (start|stop|restart|attach|show|enable|disable) for the
# local roles with a container. `homun <object> --help` lists an object's verbs, `homun <object> <verb> --help`
# one verb's words; every command takes positional keywords, no dashed flags.
def --env main [...argv: string] {
    cli {
        if ($argv | is-empty) { try { report check }; launch-up; attach-zellij false; return }
        let key = $argv.0
        let verb = $argv | get -o 1 | default show
        if $key not-in (side-roles | columns) or $verb not-in $SIDE_VERBS {
            error make {msg: $"unknown command '($argv | str join ' ')'; `homun --help` lists the commands"}
        }
        let rest = $argv | skip 2
        let rest = if $verb in [stop restart] { guarded $rest $"($key) ($verb)" } else { $rest }
        side-verb (side-roles | get $key) $verb $rest
    }
}

# the Manager's container: make sure it runs, stop it, recreate it, print it
def --env "main container" [] { main container show }

# make sure it runs
def --env "main container start" [...rest: string] { cli { no-args $rest; try { report check }; up } }

# [force]  stop it; refused while work is ongoing (claude-busy or a held lock), unless force, -f or --force
def --env --wrapped "main container stop" [...rest: string] { cli { no-args (guarded $rest "container stop"); stop-on-purpose } }

# [only manager|editor|<role>] [with editor] [when changed] [force]  recreate it (and the mechanic's if enabled) so a rebuilt image applies, without attaching; the editor (claude-emacs) only when its planned mounts/env changed, or with `with editor` / `only editor`; refused while work is ongoing, unless force
def --env --wrapped "main container restart" [...rest: string] {
    cli {
        let rest = guarded $rest "container restart"
        # `only manager` leaves the mechanic's container alone: the form the mechanic's own
        # request is granted as (bin/claude-restart-on-request), so it does not vouch for HEAD
        # `only <role>` is one role's container, the form the rolling update uses (lib/roll.nu);
        # `when changed` then leaves a running container with an unchanged plan alone
        let opts = kw $rest {only: [all manager ...(enabled-roles | get role)], with: [none editor], when: [always changed]}
        let only = $opts.only
        # Preflight all, stop all, only then start the Manager and the enabled side roles, so
        # they follow the same wrapper update. The editor (the user's Emacs) is recreated only when
        # asked (`only editor`, `with editor`), when its planned arguments changed or when it is down
        # (a restart used to leave a stopped editor stopped).
        let notify = ensure-notify-proxy
        wayland-link
        let editor = side-plan (editor) $notify
        let plans = (if $only in [all manager] { [(side-plan (manager) $notify)] } else { [] })
            | append (if $only == all { enabled-roles | where role != editor | each {|r| side-plan $r $notify } } else { [] })
            | append (if $only not-in [all manager editor] { [(side-plan (side-roles | get $only) $notify)] } else { [] })
            | append (if $only == editor or $opts.with == editor or ($only == all and (not (is-running $EDITOR) or (plan-changed $editor))) { [$editor] } else { [] })
            | where {|p| $opts.when == always or not (is-running $p.name) or (plan-changed $p) }
        if ($plans | is-empty) { log info "Nothing to recreate: running with an unchanged plan"; return }
        log info $"Recreating: ($plans | get name | str join ', ')"
        $plans | each {|p| preflight $p }
        snapshot-before-recreate
        # Staggered, so that an agent always answers: with a mechanic among them, the manager alone
        # first, gated (lib/roll.nu); only once it is healthy the rest, and the mechanic must pass
        # its gate too. A manager that does not come back leaves the mechanic running to repair it.
        # Roles without an agent go in one wave.
        let first = $plans | where role == manager
        let rest = $plans | where role != manager
        if ($first | is-not-empty) and ($rest | any {|p| $p.role == mechanic }) {
            recreate-wave $first
            let why = roll gate $NAME
            if $why != null {
                request alarm-to mechanic repair $"role-failed: manager does not come up healthy after a restart \(($why)); the other roles were left running"
                error make {msg: $"($why); left running: ($rest | get name | str join ', ')"}
            }
            log info $"($NAME) is healthy; recreating: ($rest | get name | str join ', ')"
            recreate-wave $rest
            let why = roll gate ($rest | where role == mechanic | first | get name)
            if $why != null {
                request alarm role-failed $"role-failed: the mechanic does not come up healthy after a restart \(($why))"
                error make {msg: $why}
            }
        } else {
            recreate-wave $plans
        }
    }
}

# [<role>]  print the podman arguments and host preparation a start of that role's container would use (manager by default; editor or any role with a container), starting nothing
def --env "main container plan" [...rest: string] {
    cli {
        arity $rest 0 1 "usage: homun container plan [<role>]"
        print (plan-text ($rest | get -o 0 | default manager))
    }
}

# the role containers a restart covers, one `<role> <container>` per line in the order of a rolling update: the manager first, the mechanic (the repair crew) last
def --env "main container roles" [...rest: string] {
    cli {
        no-args $rest
        let side = enabled-roles
        print ([{role: manager, name: $NAME} ...($side | where role != mechanic) ...($side | where role == mechanic)] | each {|r| $"($r.role) ($r.name)" } | str join "\n")
    }
}

# build the image
def --env "main container build" [...rest: string] { cli { no-args $rest; need just; just -f ($SCRIPT_DIR | path join justfile) build } }

# print its name and whether it runs
def --env "main container show" [...rest: string] { cli { no-args $rest; print {name: $NAME, running: (is-running)} } }

# the Zellij session: attach, replace it, print whether it exists
def --env "main session" [] { main session show }

# [via zellij|podman]  attach, via podman straight to Claude
def --env "main session attach" [...rest: string] {
    cli {
        let via = (kw $rest {via: [zellij podman]}).via
        if $via == podman { up; exec ($SCRIPT_DIR | path join bin claude-attach) $NAME }
        launch-up
        attach-zellij false
    }
}

# [force]  end the session for a fresh one; refused while work is ongoing (claude-busy or a held lock), unless force, -f or --force
def --env --wrapped "main session replace" [...rest: string] { cli { no-args (guarded $rest "session replace"); launch-up; attach-zellij true } }

# print whether it exists
def --env "main session show" [...rest: string] {
    cli {
        no-args $rest
        need zellij
        print {name: $NAME, exists: ($NAME in (zellij-sessions))}
    }
}

# homun.service, a systemd user unit that owns the container and the Zellij session outside any graphical login
def --env "main service" [] { main service show }

# install and enable it in ~/.config/systemd/user; launches then attach to its session
def --env "main service add" [...rest: string] { cli { host-only; no-args $rest; service-add } }

# disable and remove it (a running session stays)
def --env "main service del" [...rest: string] { cli { host-only; no-args $rest; service-del } }

# print installed, enabled, active and whether lingering is on
def --env "main service show" [...rest: string] { cli { host-only; no-args $rest; print (service-show) } }

# what the unit runs: start the container and a detached session
def --env "main service run" [...rest: string] { cli { no-args $rest; service-run } }

# a plain shell in the container
def --env "main shell" [...rest: string] { cli { no-args $rest; up; exec podman exec -it $NAME /usr/local/bin/nu } }

# the image the role containers run; a new one is built and rolled out by a home-manager switch (the host service follows the pin; `just update` in the checkout on a host without one), never from here
def --env "main image" [] { main image show }

# the staged and the running image, each role's current and previous image
def --env "main image show" [...rest: string] { cli { image-verb show $rest } }

# <role> [force]  recreate one role's container on the current image and check it against the health gate
def --env "main image retry" [...rest: string] { cli { image-verb retry $rest } }

# <role> [force]  recreate one role's container on its previous image (the last one that passed the health gate)
def --env "main image rollback" [...rest: string] { cli { image-verb rollback $rest } }

# New code and a new image come with a home-manager switch (the host service follows the pin and runs
# `bin/claude-update sync`); here only what acts on the images as they are
def --env image-verb [verb: string, rest: list<string>] {
    host-only
    if (if $verb == show { $rest != [] } else { ($rest | length) not-in [1 2] or ($rest | get -o 1 | default force) != force }) {
        error make {msg: "usage: homun image show | homun image retry|rollback <role> [force]"}
    }
    need podman
    update-env
    nu ($SCRIPT_DIR | path join bin claude-update) $verb ...$rest
}

# the host service homun-host: the one user unit that answers the containers' requests (~/claude/.services/host/requests), keeps the role containers up, checks filed reports and follows the pin (~/.config/homun/pin)
def --env "main host" [] { main host show }

# what the unit runs: the loop, in the foreground
def --env "main host run" [...rest: string] { cli { host-verb run $rest } }

# the unit's state, the pinned commit against the checked-out one, the last 10 requests with their results, recent failures
def --env "main host show" [...rest: string] { cli { host-verb show $rest } }

# [force]  follow the pin and build and roll the image now, in the foreground; a commit whose sync failed is tried again; force moves the checkout over unpublished commits
def --env "main host sync" [...rest: string] { cli { host-verb sync $rest } }

def --env host-verb [verb: string, rest: list<string>] {
    host-only
    if ($verb == sync and $rest not-in [[] [force]]) or ($verb != sync and $rest != []) { error make {msg: "usage: homun host run | show | sync [force]"} }
    need git podman
    exec nu ($SCRIPT_DIR | path join bin homun-host) $verb ...$rest
}

# add|del|show  install and start homun-host.service in ~/.config/systemd/user, remove it, or print its state
def --env "main host systemd" [...rest: string] {
    cli {
        host-only
        match $rest {
            [add] => { host-unit-add }
            [del] => { host-unit-del }
            [show] | [] => { print (host-unit-show) }
            _ => { error make {msg: "usage: homun host systemd add|del|show"} }
        }
    }
}

# host paths bound into the container
def --env "main mount" [] { main mount show }

# <path> [ro|rw]  bind a path, read-only unless rw
def --env "main mount add" [...rest: string] {
    cli {
        host-only
        let mode = $rest | get -o 1 | default ro
        arity $rest 1 2 "usage: homun mount add <path> [ro|rw]"
        if $mode not-in $mounts.MODES {
            error make {msg: $"mount mode must be one of ($mounts.MODES | str join '|'), not '($mode)'"}
        }
        mounts add $NAME ($rest.0 | path expand) $mode
    }
}

# <path> [force]  unbind a path; refused while work is ongoing (claude-busy or a held lock), unless force, -f or --force
def --env --wrapped "main mount del" [...rest: string] {
    cli {
        host-only
        let rest = guarded $rest "mount del"
        arity $rest 1 1 "usage: homun mount del <path>"
        mounts remove $NAME ($rest.0 | path expand)
    }
}

# list the mounts
def --env "main mount show" [...rest: string] { cli { host-only; no-args $rest; print (mounts list $NAME) } }

# forwarded ports
def --env "main port" [] { main port show }

# <spec> [from container|host] [scope host|lan]  open a port
def --env "main port add" [...rest: string] {
    cli {
        host-only
        arity $rest 1 null "usage: homun port add <spec> [from container|host] [scope host|lan]"
        let opts = kw ($rest | skip 1) {from: $ports.FROM, scope: $ports.SCOPE}
        ports open $NAME $rest.0 $opts.from $opts.scope
    }
}

# <spec> [from container|host] [force]  close a port; refused while work is ongoing (claude-busy or a held lock), unless force, -f or --force
def --env --wrapped "main port del" [...rest: string] {
    cli {
        host-only
        let rest = guarded $rest "port del"
        arity $rest 1 null "usage: homun port del <spec> [from container|host]"
        let opts = kw ($rest | skip 1) {from: $ports.FROM}
        ports close $rest.0 $opts.from
    }
}

# list the ports
def --env "main port show" [...rest: string] { cli { host-only; no-args $rest; print (ports list) } }

# the GPU: pass /dev/dri into the container
def --env "main gpu" [] { main gpu show }

# declare it; applies at the next recreate (`container restart`, C-SPC u)
def --env "main gpu on" [...rest: string] { cli { host-only; no-args $rest; device-set gpu true } }

# remove the declaration; applies at the next recreate
def --env "main gpu off" [...rest: string] { cli { host-only; no-args $rest; device-set gpu false } }

# print on|off and whether the running container has /dev/dri
def --env "main gpu show" [...rest: string] { cli { host-only; no-args $rest; device-show gpu /dev/dri } }

# KVM: pass /dev/kvm into the container (hardware-accelerated emulators and VMs)
def --env "main kvm" [] { main kvm show }

# declare it; applies at the next recreate (`container restart`, C-SPC u)
def --env "main kvm on" [...rest: string] { cli { host-only; no-args $rest; device-set kvm true } }

# remove the declaration; applies at the next recreate
def --env "main kvm off" [...rest: string] { cli { host-only; no-args $rest; device-set kvm false } }

# print on|off and whether the running container has /dev/kvm
def --env "main kvm show" [...rest: string] { cli { host-only; no-args $rest; device-show kvm /dev/kvm } }

def device-show [device: string, node: string] {
    let live = if (is-running $NAME) {
        (podman inspect $NAME --format '{{json .HostConfig.Devices}}' | complete).stdout | str contains $node
    } else { false }
    let on = if $device == gpu { gpu-enabled } else { kvm-enabled }
    print $"(if $on { 'on' } else { 'off' }); running container has ($node): ($live)"
}

# the roles: built-in (roles/roles.toml) and host-local (~/.config/homun/roles/<key>.json, docs/custom-roles.md)
def --env "main role" [] { main role show }

# list every role, marking local ones (override or new)
def --env "main role show" [...rest: string] {
    cli {
        no-args $rest
        let local = roles local
        let shipped = roles shipped
        print (roles load | transpose key role | each {|r| {
            key: $r.key, name: ($r.role.name? | default ""), status: ($r.role.status? | default "")
            local: (if $r.key not-in ($local | columns) { "" } else if $r.key in ($shipped | columns) { "override" } else { "new" })
            container: ($r.role.container? | default false)
        } })
    }
}

# <key>  write a local role file to edit: an override of a built-in role, else a new role
def --env "main role add" [...rest: string] {
    cli {
        host-only
        if ($rest | length) != 1 or not ($rest.0 =~ '^[a-z][a-z0-9-]*$') { error make {msg: "usage: homun role add <key>  (lowercase letters, digits, -)"} }
        let f = roles file $rest.0
        if ($f | path exists) { error make {msg: $"($f) exists already"} }
        let shipped = roles shipped
        mkdir (roles dir)
        # An override starts empty (only the fields it sets change), a new role from the scaffold
        (if $rest.0 in ($shipped | columns) { {name: ($shipped | get $rest.0 | get name)} } else { roles scaffold $rest.0 }) | to json | save $f
        log info $"wrote ($f); edit it, then `homun container restart` \(a role with "container": true then runs as homun-($rest.0)\)"
    }
}

# <key>  remove a local role file (and stop its container)
def --env "main role del" [...rest: string] {
    cli {
        host-only
        arity $rest 1 1 "usage: homun role del <key>"
        let f = roles file $rest.0
        if not ($f | path exists) { error make {msg: $"($rest.0) is not a local role \(no ($f)\)"} }
        let own = side-roles | get -o $rest.0
        if $own != null and $rest.0 not-in (roles shipped | columns) and (is-running $own.name) { stop-on-purpose $own.name }
        rm $f
    }
}

# <key> [headless|terminal]  show or set how the role's session runs, live and without a recreate: terminal is Claude Code's own interface in its tab; headless is `claude -p` behind the session broker, shown in the cockpit, with a read-only view of its stream in the tab. The same session is resumed; the turn it was in is interrupted
def --env "main role mode" [...rest: string] {
    cli {
        # How the role's session runs (container/start.sh, "Session mode"): the file is on the
        # shared mount, so this works on the host and in any container, and applies live
        let known = roles load | columns
        if ($rest | is-empty) or ($rest | length) > 2 or $rest.0 not-in $known or (($rest | length) == 2 and $rest.1 not-in [headless terminal]) {
            error make {msg: $"usage: homun role mode <key> [headless|terminal], a role of: ($known | str join ', ')"}
        }
        let dir = root | path join .services $rest.0
        if ($rest | length) == 2 { $"($rest.1)\n" | store ($dir | path join session-mode) }
        let first = {|name| let f = $dir | path join $name; if ($f | path exists) { open --raw $f | lines | get -o 0 | default "" } else { "" } }
        let asked = do $first session-mode
        let running = do $first session-running
        print $"asked: (if $asked == '' { 'the role default' } else { $asked })  running: (if $running == '' { 'unknown (its start.sh does not report it yet: restart that container once)' } else { $running })"
    }
}

# <key>  start the container of a role that has one (the mechanic's, a local role with "container": true)
def --env "main role start" [...rest: string] { cli { role-verb start $rest } }

# <key> [force]  stop it; refused while work is ongoing, unless force
def --env --wrapped "main role stop" [...rest: string] { cli { role-verb stop (guarded $rest "role stop") } }

# <key> [force]  recreate it; refused while work is ongoing, unless force
def --env --wrapped "main role restart" [...rest: string] { cli { role-verb restart (guarded $rest "role restart") } }

# <key> [via claude|shell]  attach to it; a role whose seat is a pane has its session started in the container it lives in (a second one is refused)
def --env "main role attach" [...rest: string] { cli { role-verb attach $rest } }

def --env role-verb [verb: string, rest: list<string>] {
    if $verb == attach and (pane-role ($rest | get -o 0)) != null {
        # A role whose seat is a pane: its session is the launcher every role starts with, run
        # in the container of the role its manifest names
        let pane = pane-role $rest.0
        no-args ($rest | skip 1)
        if not (roles enabled $rest.0) { error make {msg: $"($rest.0) is not enabled on this host: add it to roles in the host config"} }
        exec podman exec -it --env TERM --env $"CLAUDE_ROLE=($rest.0)" $pane sh /opt/homun/start.sh
    }
    let seated = side-roles | reject editor
    if ($rest | is-empty) or $rest.0 not-in ($seated | columns) { error make {msg: $"usage: homun role ($verb) <key>, a role with a container of its own: ($seated | columns | str join ', ')"} }
    side-verb ($seated | get $rest.0) $verb ($rest | skip 1)
}

# the mechanic's container, claude-mechanic (the mechanic tab)
def --env "main mechanic" [] { main mechanic show }

# make sure it runs
def --env "main mechanic start" [...rest: string] { cli { side-verb (side-roles | get mechanic) start $rest } }

# [force]  stop it; refused while work is ongoing (claude-busy or a held lock), unless force, -f or --force
def --env --wrapped "main mechanic stop" [...rest: string] { cli { side-verb (side-roles | get mechanic) stop (guarded $rest "mechanic stop") } }

# [force]  recreate it so a rebuilt image applies; refused while work is ongoing (claude-busy or a held lock), unless force, -f or --force
def --env --wrapped "main mechanic restart" [...rest: string] { cli { side-verb (side-roles | get mechanic) restart (guarded $rest "mechanic restart") } }

# [via claude|shell]  attach to its Claude, or open a shell in it
def --env "main mechanic attach" [...rest: string] { cli { side-verb (side-roles | get mechanic) attach $rest } }

# print its name, whether it runs and whether it is enabled
def --env "main mechanic show" [...rest: string] { cli { side-verb (side-roles | get mechanic) show $rest } }

# start it with the Manager's container and recreate it on `container restart`
def --env "main mechanic enable" [...rest: string] { cli { side-verb (side-roles | get mechanic) enable $rest } }

# no longer start it with the Manager's container (a running one stays)
def --env "main mechanic disable" [...rest: string] { cli { side-verb (side-roles | get mechanic) disable $rest } }

# Emacs's container, claude-emacs (always started with the Manager's; `homun emacs` opens a frame)
def --env "main editor" [] { main editor show }

# make sure it runs
def --env "main editor start" [...rest: string] { cli { side-verb (side-roles | get editor) start $rest } }

# stop it (Emacs frames close)
def --env "main editor stop" [...rest: string] { cli { side-verb (side-roles | get editor) stop $rest } }

# recreate it so a rebuilt image applies
def --env "main editor restart" [...rest: string] { cli { side-verb (side-roles | get editor) restart $rest } }

# a shell in it
def --env "main editor attach" [...rest: string] { cli { side-verb (side-roles | get editor) attach $rest } }

# print its name and whether it runs
def --env "main editor show" [...rest: string] { cli { side-verb (side-roles | get editor) show $rest } }

# an Emacs frame in this terminal (emacsclient -t), e.g. over SSH from the phone
def --env "main editor tty" [...rest: string] {
    cli {
        # A terminal frame of the daemon in this terminal (an SSH session from the phone): emacsclient
        # runs inside the container so the daemon can open its pty; TERM and COLORTERM go along
        host-only
        no-args $rest
        ensure-container (side-plan (editor) null)
        let socket = $env.HOME | path join claude .services emacs socket
        let term = $env.TERM? | default xterm-256color
        let color = $env.COLORTERM? | default ""
        exec podman exec -it -e $"TERM=($term)" -e $"COLORTERM=($color)" $EDITOR /nix/var/nix/profiles/emacs/bin/emacsclient -t -s $socket
    }
}

# <url> [name]  clone a repository into ~/claude/.bare
def --env "main clone" [...rest: string] {
    cli {
        host-only
        arity $rest 1 2 "usage: homun clone <url> [name]"
        let repo = clone (root | path join .bare) $rest.0 ($rest | get -o 1)
        log info $'Cloned into ($repo)'
    }
}

# [<file> [<line>]]  open an Emacs frame
def --env "main emacs" [...rest: string] {
    cli {
        host-only
        arity $rest 0 2 "usage: homun emacs [<file> [<line>]]"
        let target = [($rest | get -o 0 | if $in != null { path expand }) ($rest | get -o 1)] | compact
        nu ($SCRIPT_DIR | path join bin claude-emacs) frame ...$target
    }
}

# run ~/claude/.bin/<name> [args...] on the host; no name or show lists them
def --env "main cmd" [...rest: string] { cli { host-only; bin-cmd run $rest } }

# like cmd, but copy ~/claude/.bin/<name> [args...] (its full path, or the string of its `let remote = '...'` line) to the Wayland clipboard instead of running it, after showing it and asking y/N
def --env "main clip" [...rest: string] { cli { host-only; bin-cmd clip $rest } }

# <file> [for <duration>]  give a host file to anyone as one https link (copied to the clipboard), default 24h; `list` shows live links, `del <token>` removes one
def --env "main share" [...rest: string] { cli { host-only; share-cmd $rest } }

# <file> [for <duration>] [close grace|confirm|bytes]  stream a host file to anyone through one link, waiting here until it closes (C-c ends it); `list`, `stop <id>`
def --env "main send" [...rest: string] { cli { host-only; send-cmd $rest } }

# the remote cockpit (the cockpit's Elisp in another Emacs, e.g. Android Emacs over the VPN): its gateway at /cockpit-gateway/ behind the proxy and the device keys it accepts
def --env "main cockpit" [] { show-help cockpit }

# add <name> [secrets] [approve] [readonly] [alarms] | del <name> | show  a device key (printed once) and what it may do: secrets sends secret-widget values, approve answers permission prompts, readonly only reads, alarms gets the user's alarms; the first device starts the gateway, deleting the last stops it; add also prints the device's init.el lines
def --env "main cockpit device" [...rest: string] { cli { host-only; cockpit-device $rest } }

# [file] <title> [with logs] | show [n] | reply <n> <text> | check  file a bug report as an issue in the private repo of host config key report.repo; the body comes from stdin or $EDITOR; `with logs` adds redacted tails of the start, update and supervisor logs; show lists this host's reports or one thread, reply comments, check reports closed fixes and replies; token in ~/.config/homun/report-token (mode 600); never put personal names, role names or identities, usernames or host-identifying details in a report (use role words and generic placeholders)
def --env "main report" [...rest: string] {
    cli {
        # inside a container the host files it: the spool client, the token stays on the host
        if (hostcfg in-container) { ^python3 ($SCRIPT_DIR | path join bin homun-report) ...$rest } else { report $rest }
    }
}

# [--since <duration>] [-n <rows>] [-w <width>] [--json]  usage report
def --env --wrapped "main usage" [...rest: string] { cli { host-only; usage-report $rest } }

# [json]  the health of every container, service and component, one check each with a status (ok, warn, fail, unknown), the key facts and a hint when it is not ok; json prints the checks as one object; exit 1 when a check fails
def --env "main doctor" [...rest: string] {
    cli {
        if $rest not-in [[] [json]] { error make {msg: "usage: homun doctor [json]"} }
        exec nu ($SCRIPT_DIR | path join container homun-doctor) ...$rest
    }
}

# project tabs: a Claude session per workspace (C-SPC P)
def --env "main tab" [] { show-help tab }

# <workspace> [name <n>]  open a tab running a project session in ~/claude/<workspace>
def --env "main tab add" [...rest: string] {
    cli {
        host-only
        arity $rest 1 null "usage: homun tab add <workspace> [name <n>]"
        let ws = $rest.0
        let name = (kw ($rest | skip 1) {name: []}).name | default $ws
        project-tab $ws $name
    }
}

# run a host command and alarm the Manager when it fails or logs an error (`run` may be left out)
def --env --wrapped "main watch" [...rest: string] {
    cli { if ($rest | is-empty) { show-help watch } else { host-only; exec $nu.current-exe ($SCRIPT_DIR | path join bin claude-watch) run ...$rest } }
}

# [name <n>] [error <regex>|none] [tail <lines>] -- <cmd...>  tee to ~/claude/.services/watch/runs/, fire on a non-zero exit or a matching line
def --env --wrapped "main watch run" [...rest: string] { cli { host-only; exec $nu.current-exe ($SCRIPT_DIR | path join bin claude-watch) run ...$rest } }

# the recent runs
def --env --wrapped "main watch list" [...rest: string] { cli { host-only; exec $nu.current-exe ($SCRIPT_DIR | path join bin claude-watch) list ...$rest } }

# [<id>]  one run with its event and log tail, or the recent runs
def --env --wrapped "main watch show" [...rest: string] { cli { host-only; exec $nu.current-exe ($SCRIPT_DIR | path join bin claude-watch) show ...$rest } }

# `homun tab add`: a Zellij tab named `name` running a project session (container/project)
# in the workspace. Layouts take no arguments, so zellij/project.kdl is rendered per launch
# like the main layout plus the workspace, name and bin directory.
def --env project-tab [ws: string, name: string] {
    if ($env.ZELLIJ_SESSION_NAME? | default "") != $NAME {
        error make {msg: $"homun tab add only works inside the ($NAME) Zellij session"}
    }
    for word in [$ws $name] {
        if not ($word =~ '^[A-Za-z0-9_-][A-Za-z0-9._-]*$') {
            error make {msg: $"'($word)' is not a plain name \([A-Za-z0-9._-], not starting with .)"}
        }
    }
    let dir = root | path join $ws
    if not ($dir | path exists) { error make {msg: $"no workspace ($dir)"} }
    need zellij
    let layout = runtime-dir | path join $"homun-tab-($name).kdl"
    let partial = $"($layout).($nu.pid)"
    open --raw ($SCRIPT_DIR | path join zellij project.kdl)
    | str replace -a '@WS@' $ws
    | str replace -a '@NAME@' $name
    | str replace -a '@BIN@' ($SCRIPT_DIR | path join bin)
    | save -f $partial
    mv -f $partial $layout
    zellij action new-tab --name $name --layout $layout
}

# `homun usage` flags, passed on to bin/claude-usage; --since takes a duration
def usage-report [flags: list<string>] {
    mut out = []
    mut i = 0
    while $i < ($flags | length) {
        let flag = $flags | get $i
        match $flag {
            "--json" => { $out = $out | append $flag; $i += 1 }
            "--since" | "--last" | "-n" | "--width" | "-w" => {
                let value = $flags | get -o ($i + 1)
                if $value == null { error make {msg: $"($flag) needs a value"} }
                let value = if $flag == "--since" { $"($value | into duration | into int)ns" } else { $value }
                $out = $out | append [(match $flag { "-n" => "--last", "-w" => "--width", _ => $flag }) $value]
                $i += 2
            }
            _ => { error make {msg: $"unknown usage flag '($flag)'"} }
        }
    }
    nu ($SCRIPT_DIR | path join bin claude-usage) (state | path join claude usage.jsonl) ...$out
}

# Print a user-facing error as `homun: <msg>` plus its hint lines and exit 1, without Nushell's
# error box and source spans; HOMUN_DEBUG=1 keeps the full trace.
def fail [err: record] {
    if ($env.HOMUN_DEBUG? | is-not-empty) { error make $err.raw }
    let lines = $err.msg | lines | enumerate | each {|l| if $l.index == 0 { $"homun: ($l.item)" } else { $l.item } }
    print -e ($lines | str join "\n")
    exit 1
}
