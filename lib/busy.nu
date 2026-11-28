# The one "work is ongoing" signal, read by the host: claude-busy in the Manager's container
# plus the GPU and Deck deploy locks. A failed probe counts as work; a stopped container is idle.
export def ongoing [name: string]: nothing -> list<string> {
    let up = ^podman inspect --format '{{.State.Running}}' $name | complete
    if ($up.stdout | str trim) != "true" { return [] }
    let busy = ^timeout 10 podman exec $name claude-busy | complete
    let work = $busy.stdout | lines
    let dir = $env.HOME | path join claude .services locks
    let held = [gpu.lock deck-deploy.lock] | where {|l| ($dir | path join $l | path exists) and (^flock -n ($dir | path join $l) true | complete).exit_code != 0 }
    (if $busy.exit_code == 0 { [] } else if ($work | is-empty) { ["unknown: claude-busy failed"] } else { $work }) | append ($held | each {|l| $"lock ($l) held" })
}

# Refuse (exit 1) naming the work and the forcing command, unless forced
export def guard [force: bool, name: string, cmd: string] {
    let work = if $force { [] } else { ongoing $name }
    if ($work | is-not-empty) { print -e $"work ongoing: ($work | first 3 | str join '; '); to force: ($cmd) force"; exit 1 }
}
