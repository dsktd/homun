# Roles. Shipped ones are a table each in roles/roles.toml in the checkout: the fields of the
# registry container/roles.json (built from them by bin/claude-roles build, for the readers inside
# the containers) plus `order` (their place in lists) and what the launcher builds a role's
# container from:
#   seat     {kind: container|pane|none, in, name, state}: where the role lives. A container's
#            `name` (default homun-<key>) and `state`, the directory of its Claude state under the
#            state root (default <key>; "" is the root itself). A `pane` is a session started in
#            the container of the role `in` names (container/start.sh with CLAUDE_ROLE=<key>).
#   session  how the session is launched (container/start.sh, through container/role-manifest.sh):
#            workdir (default @root), seed ({src, dst}: a file of the checkout copied to `dst`
#            once, when nothing is there yet), mode (`terminal`, the default, or `headless`;
#            `homun role mode <key>` flips it live over this value), name (the session's plate,
#            default the key), model, settings (a settings file under container/, its @HOME@
#            filled in), identity (`agent`: the agent identity's text; else the role's own),
#            first_prompt (what a start says first; default: wait for the user), relay (run under
#            compact-relay), rotate (honour the session-rotate marker), recycle (false: an ended
#            idle session is not started fresh), boot_record (record each start and its timing
#            under .services/<key>), impl (`homund`: `homund session` runs the broker, the
#            compact relay, the rotation and the recycle in place of the scripts; default
#            `scripts`).
#   access   what the container reaches beyond ~/claude and its own state, all off by default:
#            gh (its own gh state), notify (the desktop notification socket), wayland (the host's
#            Wayland socket), cpuset (pinned to the host config's cpuset), secrets (ro|rw: the
#            user's secret inbox), volumes ([{name, at}] named volumes), read_state_of (other
#            roles' Claude state, read-only with the credentials hidden: a key mounts it at
#            /mnt/<key>-claude, {role, at: "@host"} at its host path), live_mounts (target of
#            `homun mount` and `homun port`), update (its exit 75 asks for a recreate; it takes
#            the request from inside and is told of a failed update), services (its container
#            runs the service supervisor).
#   wake     how the session is woken: channel ({plugin: a channel plugin of container/channels,
#            state: the directory of its token, when: a file that must exist, env: {KEY: value}
#            exported for it, first_prompt: the first prompt once it is installed}) and watch
#            ([{kind: "script", cmd: a script under container/, log, needs: "channel"}], started
#            with the session and ended with it).
#   health   the shell command of the container's health check, none by default.
#   restart  "none" for no restart policy; by default podman restarts it on failure.
# Paths in them start with @root (~/claude), @home or @state (the role's own state directory).
# Host-local roles: one <key>.json per role in ${XDG_CONFIG_HOME:-~/.config}/homun/roles/, never in
# the repo. A file whose key is a shipped role overrides that role's fields (name,
# pronouns, emoji, colour, identity, model, ...); any other key is a new role with the same fields.
# `"container": true` gives a new role its own container (short for `seat: {kind: container}`),
# started like the mechanic's (`homun role start <key>`) and with every `container restart`. The
# directory is mounted read-only at /run/homun-roles.

use hostcfg.nu

export const MOUNT = "/run/homun-roles"

const SHIPPED = path self | path dirname | path dirname | path join roles roles.toml

# The shipped roles: {key: <its manifest>}, in the manifests' `order`
export def shipped []: nothing -> record {
    let all = open $SHIPPED
    $all | columns | each {|k| {key: $k, order: ($all | get $k | get order? | default 1000)} } | sort-by order key
    | reduce -f {} {|r, acc| $acc | insert $r.key ($all | get $r.key) }
}

# Every role: the shipped manifests with the host's files laid over them, field by field (a record
# merges, a list or any other value replaces)
export def load []: nothing -> record { shipped | merge deep --strategy overwrite (local) }

export def dir []: nothing -> path {
    ($env.XDG_CONFIG_HOME? | default ($env.HOME | path join .config)) | path join homun roles
}

export def file [key: string]: nothing -> path { dir | path join $"($key).json" }

# The local roles: {key: <its file's record>}
export def local []: nothing -> record {
    if not (dir | path exists) { return {} }
    ls (dir) | where name =~ '\.json$' | reduce -f {} {|f, acc|
        $acc | insert ($f.name | path parse | get stem) (open --raw $f.name | from json)
    }
}

# The role the session and the cockpit open on. Its container is the one a bare `homun` attaches
# to, it is always enabled, and it is what CLAUDE_ROLE means inside a container that is not told.
export const PRIMARY = "manager"

# The roles with a container of their own, in the manifests' order:
# [{role, name, state (under the state root), manifest}]
export def seated []: nothing -> list<record> {
    load | transpose role manifest | each {|r|
        let seat = $r.manifest.seat? | default {}
        let kind = $seat.kind? | default (if ($r.manifest.container? | default false) { "container" } else { "none" })
        {role: $r.role, kind: $kind, name: ($seat.name? | default $"homun-($r.role)"), state: ($seat.state? | default $r.role), manifest: $r.manifest}
    } | where kind == container | reject kind
}

# Left by `homun <role> enable` (host-only config, never mounted)
export def marker [key: string]: nothing -> path { $env.HOME | path join .config claude $key }

# Does this host run the role? The primary always; a host-local role by its file; a shipped one
# by its marker or the `roles` list of the host config
export def enabled [key: string]: nothing -> bool {
    $key == $PRIMARY or $key not-in (shipped | columns) or (marker $key | path exists) or ($key in (hostcfg value roles []))
}

# A new role's file: the fields of the registry, neutral placeholders
export def scaffold [key: string]: nothing -> record {
    {
        name: ($key | str capitalize), status: active, emoji: "🔹", colour: [128 128 128]
        job: "What this role does.", trigger: "When it runs or is woken.", model: "Sonnet, low effort."
        may: "What it may do.", never: "What it must not do.", reports: "Where its results go."
        identity: $"You are the ($key) role."
        container: false
    }
}
