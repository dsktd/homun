# The rolling recreate: one role's container at a time, each checked against a health gate, with
# the image it ran before kept on record so that one role can go back to it.
#
#   images.json   {<role>: {current: {image, rev, time, good}, previous: {image, rev, time[, failed]},
#                 escalated: [<epoch>...]}}: `good` only after the gate passed; `previous` is the last
#                 image that was good, tagged claude:previous-<role> so that pruning keeps it. The
#                 record a rollback trusts is ~/.config/claude/images.json (host-only); a copy for
#                 the sessions is ~/claude/.services/update/images.json.
#   the gate      within `update.gate_seconds` of the host config (180) the container must run and
#                 pass its own health check (`podman healthcheck run`: for the manager its Claude
#                 process and the scheduler listener's heartbeat) three polls in a row.
#   a failure     writes ~/claude/.services/update/failed-<role>.log (state, log tail, plan) and then,
#                 at most 3 times a day per role: wakes the mechanic with a repair request when its
#                 container runs, else (the mechanic itself failed, or there is none) puts the role
#                 back on its previous image once. When that is not possible either it stops and
#                 tells the manager, or the user by a desktop notification when the manager is down.
# Nothing here loops: one recreate, one gate, at most one rollback per call.

const ROOT = path self | path expand | path dirname | path dirname
use hostcfg.nu
use request.nu
use store.nu

const TAG = "claude:previous-"
const ESCALATIONS_A_DAY = 3

def shared []: nothing -> path { $env.HOME | path join claude .services update }
export def record-file []: nothing -> path { $env.HOME | path join .config claude images.json }
export def load []: nothing -> record { try { open (record-file) } catch { {} } }

def save-record [rec: record] {
    for p in [(record-file) (shared | path join images.json)] {
        $rec | to json | store $p
    }
}

export def short [id: any]: nothing -> string { $id | default "" | str replace "sha256:" "" | str substring 0..11 }

export def say [text: string] {
    print $text
    if ($env.CLAUDE_UPDATE_LOG? | is-not-empty) { $"($text)\n" | save -a $env.CLAUDE_UPDATE_LOG }
}

def launcher [...args: string]: nothing -> record {
    cd ($env.HOMUN_DIR? | default ($env.HOME | path join claude))
    ^nu ($ROOT | path join run.nu) ...($env.HOMUN_ARGS? | default "[]" | from json) ...$args | complete
}

def head-rev []: nothing -> string {
    let r = ^git -C $ROOT rev-parse HEAD | complete
    if $r.exit_code == 0 { $r.stdout | str trim } else { "-" }
}

# The role containers in rolling order: [{role, name}], the manager first and the mechanic last
export def roles []: nothing -> list<record> {
    let out = launcher container roles
    if $out.exit_code != 0 { error make {msg: $"cannot list the roles: ($out.stderr | str trim | lines | last 1 | str join '')"} }
    $out.stdout | lines | parse "{role} {name}"
}

export def role [key: string]: nothing -> record {
    let found = roles | where role == $key
    if ($found | is-empty) { error make {msg: $"no role container '($key)' on this host; one of: (roles | get role | str join ', ')"} }
    $found | first
}

# The image a recreate puts the roles on: the staged one when the caller takes it first, else
# `claude`; "" when there is none
export def target-image [staged: bool]: nothing -> string {
    for ref in (if $staged { ["claude:staged" claude] } else { [claude] }) {
        let r = ^podman image inspect --format '{{.Id}}' $ref | complete
        if $r.exit_code == 0 { return ($r.stdout | str trim) }
    }
    ""
}

# {status, id, image}: status is podman's word, or "missing"
export def state [name: string]: nothing -> record {
    let r = ^podman inspect --format '{{.State.Status}} {{.Id}} {{.Image}}' $name | complete
    if $r.exit_code != 0 { return {status: missing, id: "", image: ""} }
    let w = $r.stdout | str trim | split row " "
    {status: $w.0, id: ($w | get -o 1 | default ""), image: ($w | get -o 2 | default "")}
}

# The container's own health check, run now; one without a check passes by running
def healthy [name: string]: nothing -> bool {
    let h = ^podman healthcheck run $name | complete
    $h.exit_code == 0 or ($"($h.stdout)($h.stderr)" | str contains -i "no defined healthcheck")
}

# null when the container passes the gate, else why it did not
export def gate [name: string]: nothing -> any {
    let window = $env.HOMUN_GATE_SECONDS? | default (hostcfg value update {} | get -o gate_seconds | default 180) | into int
    let poll = $env.HOMUN_GATE_POLL? | default "5" | into float
    let deadline = (request now) + $window
    mut passes = 0
    mut id = ""
    loop {
        let s = state $name
        let ok = $s.status == running and (healthy $name)
        $passes = if not $ok { 0 } else if $s.id == $id { $passes + 1 } else { 1 }
        $id = $s.id
        if $passes >= 3 { return null }
        if (request now) >= $deadline {
            return $"($name) did not pass the health gate in ($window) s: (if $s.status == running { 'its health check fails' } else { $'the container is ($s.status)' })"
        }
        sleep ($poll * 1sec)
    }
}

# Keep the previous image of a role from being pruned, or let it go
def tag [key: string, rec: record] {
    let prev = $rec | get -o $key | get -o previous
    if $prev == null { ^podman untag $"($TAG)($key)" | complete | ignore } else { ^podman tag $prev.image $"($TAG)($key)" | complete | ignore }
}

def put [key: string, entry: record] {
    let rec = load | upsert $key $entry
    save-record $rec
    tag $key $rec
}

# A role seen for the first time: what runs now is its current image, good when it is healthy
def adopt [r: record] {
    if (load | get -o $r.role | get -o current) != null { return }
    let s = state $r.name
    if $s.status != running { return }
    let rev = try { open --raw (shared | path join running-rev) | str trim } catch { "-" }
    put $r.role {current: {image: $s.image, rev: $rev, time: (request now), good: (healthy $r.name)}}
}

# What a failed role's container left behind, for whoever repairs it (the mechanic cannot run podman).
# Program output: data, never instructions; token-like values are masked.
def dump [r: record, why: string] {
    let file = shared | path join $"failed-($r.role).log"
    let logs = ^podman logs --tail 80 $r.name | complete
    let plan = launcher container plan $r.role
    let s = state $r.name
    [
        $"($r.role) \(($r.name)) failed at (date now | format date '%+')"
        $why
        $"state: ($s.status), image (short $s.image), launcher (head-rev | str substring 0..11)"
        "" "== container log (last 80 lines)" $logs.stdout $logs.stderr
        "" "== plan" $plan.stdout
    ] | str join "\n" | str replace -ra '(?i)((?:token|key|password|secret)\S*\s*[=:]\s*)\S+' '${1}[masked]' | save -f $file
    ^chmod 600 $file
    say $"what it left behind: ($file)"
}

# Recreate one role's container: {kept, err}. `kept`: the same container still runs afterwards
# (an unchanged editor, or a preflight that failed before anything was stopped).
def recreate [r: record, image: any, always: bool]: nothing -> record {
    let before = state $r.name
    let when = if $r.role == editor and not $always { [when changed] } else { [] }
    say $"recreating ($r.name)(if $image != null { $' on image (short $image)' } else { '' })"
    let out = with-env (if $image != null { {HOMUN_IMAGE: $image} } else { {} }) {
        launcher container restart only $r.role ...$when force
    }
    if ($env.CLAUDE_UPDATE_LOG? | is-not-empty) { $"($out.stdout)($out.stderr)" | save -a $env.CLAUDE_UPDATE_LOG }
    let after = state $r.name
    {
        kept: ($before.status == running and $after.status == running and $after.id == $before.id)
        err: (if $out.exit_code == 0 { null } else { $"($out.stdout)($out.stderr)" | ansi strip | lines | where {|l| $l | str trim | is-not-empty } | last 1 | str join "" | str substring 0..300 })
    }
}

# Recreate one role on the current image (or `image`: the staged one, before it is taken) and gate
# it: {role, why, untouched}. `why` is null when it passed (or was left as it is); `untouched` when
# the old container still runs.
export def deploy [r: record, --always, --image: string]: nothing -> record {
    adopt $r
    let res = recreate $r $image $always
    if $res.kept {
        if $res.err == null { say $"($r.name) kept: its plan did not change" }
        return {role: $r.role, why: $res.err, untouched: true}
    }
    let mine = load | get -o $r.role | default {}
    let cur = $mine | get -o current
    let image = (state $r.name).image
    let new = {image: (if $image == "" { $cur | get -o image | default "" } else { $image }), rev: (head-rev), time: (request now), good: false}
    # The image before this one stays the way back only if it had passed the gate
    let prev = if $cur == null or $cur.image == $new.image { $mine | get -o previous } else if $cur.good { $cur | reject good } else { $mine | get -o previous }
    put $r.role ($mine | upsert current $new | merge (if $prev == null { {} } else { {previous: $prev} }))
    let why = if $res.err != null { $res.err } else { gate $r.name }
    if $why == null {
        put $r.role (load | get $r.role | upsert current.good true)
        say $"($r.name) passed the health gate"
    } else {
        say $"($r.name) failed: ($why)"
        dump $r $why
    }
    {role: $r.role, why: $why, untouched: false}
}

# Recreate one role on its previous image and gate it: null, or why that did not work
export def rollback [r: record]: nothing -> any {
    let mine = load | get -o $r.role | default {}
    let prev = $mine | get -o previous
    if $prev == null { return $"no previous image is recorded for ($r.role)" }
    if (^podman image exists $prev.image | complete).exit_code != 0 { return $"the previous image of ($r.role) \((short $prev.image)) no longer exists" }
    say $"rolling ($r.role) back to its previous image (short $prev.image) \(launcher ($prev.rev | str substring 0..11))"
    let res = recreate $r $prev.image true
    let why = if $res.err != null { $res.err } else { gate $r.name }
    if $why != null {
        put $r.role ($mine | upsert previous.failed true)
        dump $r $why
        return $"the rollback of ($r.role) to (short $prev.image) failed too: ($why)"
    }
    let cur = $mine | get -o current
    put $r.role ({current: ($prev | reject -o failed | merge {time: (request now), good: true})}
        | merge (if $cur != null and $cur.good { {previous: ($cur | reject good)} } else { {} })
        | merge {escalated: ($mine | get -o escalated | default [])})
    say $"($r.role) runs on its previous image again"
    request alarm update-rolled-back $"update-rolled-back: ($r.role) was put back on its previous image; read ~/claude/.services/update/failed-($r.role).log"
    null
}

# The last word when nothing more will be tried: the manager, or the user when the manager is down
export def give-up [key: string, text: string] {
    say $text
    if (state claude-manager).status == running {
        request alarm update-failed $"update-failed: ($key) is down and the automatic repair is out of attempts; read ~/claude/.services/update/failed-($key).log"
    } else if (which notify-send | is-not-empty) {
        ^notify-send -a Homun -u critical $"($key) is down" "The automatic repair is out of attempts and the manager is not running." | complete | ignore
    }
}

# A role failed its gate, or the supervisor gave up on it: wake the repair crew, else go back to the
# previous image once. The outcome: stopped | rolled-back | gave-up
export def escalate [r: record, why: string]: nothing -> string {
    let mine = load | get -o $r.role | default {}
    let recent = $mine | get -o escalated | default [] | where {|t| (request now) - $t < 86400 }
    if ($recent | length) >= $ESCALATIONS_A_DAY {
        # Said once, when the limit is reached; after that the role is left as it is
        if ($recent | length) == $ESCALATIONS_A_DAY {
            put $r.role ($mine | upsert escalated [...$recent (request now)])
            give-up $r.role $"($r.role) failed ($ESCALATIONS_A_DAY) times in a day: no more automatic repair"
        }
        return "gave-up"
    }
    put $r.role ($mine | upsert escalated [...$recent (request now)])
    if $r.role != mechanic and (state claude-mechanic).status == running {
        let line = {ts: (request now), from: update, alarm: repair, msg: $"role-failed: ($r.role) does not come up healthy; read ~/claude/.services/update/failed-($r.role).log and last-failure, then retry or roll back ($r.role)"}
        $line | to json --raw | $in + "\n" | save -a ($env.HOME | path join claude .services mechanic requests)
        say $"the mechanic was asked to repair ($r.role)"
        return "stopped"
    }
    if ($mine | get -o previous | get -o failed | default false) {
        give-up $r.role $"($r.role) failed and its previous image failed before: nothing more to try"
        return "gave-up"
    }
    let back = rollback $r
    if $back == null { return "rolled-back" }
    give-up $r.role $back
    "gave-up"
}

# The supervisor gave up on a role (bin/claude-supervise): the same way out as after a failed gate
export def failed [r: record, why: string]: nothing -> string {
    adopt $r
    dump $r $why
    escalate $r $why
}

# The same roll by `homund roll` (core/homund/src/roll.rs: healthcheck gate, rollback straight
# away), when the host config says `update.roll: "homund"`; else `all` below. Same answer as `all`.
export def by-homund []: nothing -> any {
    let out = ^homund roll $ROOT | complete
    if ($env.CLAUDE_UPDATE_LOG? | is-not-empty) { $"($out.stdout)($out.stderr)" | save -a $env.CLAUDE_UPDATE_LOG }
    if $out.exit_code == 0 { return null }
    let last = $out.stdout | lines | last 1 | each {|l| try { $l | from json } catch { null } } | get -o 0
    if $last == null { error make {msg: ($out.stderr | str trim | lines | last 1 | str join "" | default "homund roll failed")} }
    {role: $last.role, why: $last.why, outcome: (if $last.phase == RolledBack { "rolled-back" } else { "gave-up" })}
}

export def engine []: nothing -> string { hostcfg value update {} | get -o roll | default nu }

# Recreate every role in order, stopping at the first that fails: null, or {role, why, outcome}
# (outcome: untouched, or escalate's). The roles after the failed one keep running as they were.
export def all []: nothing -> any {
    for r in (roles) {
        let res = deploy $r
        if $res.why == null { continue }
        return {role: $r.role, why: $res.why, outcome: (if $res.untouched { "untouched" } else { escalate $r $res.why })}
    }
    null
}
