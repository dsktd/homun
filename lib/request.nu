# What the host service (bin/homun-host) and the scripts that answer its requests share: the clock,
# a request's age, the manager's alarm line and whether an update is running.

# Epoch seconds now
export def now []: nothing -> int { date now | format date "%s" | into int }

# Seconds since an epoch-seconds timestamp (negative when it lies in the future)
export def age [ts: int]: nothing -> int { (now) - $ts }

# One bus message through `homun-msg send`; a failure is one line on stderr, never an error
export def bus-send [to: string, name: string, msg: string] {
    let r = try { ^homun-msg send $to $name $msg | complete } catch {|e| {exit_code: 127, stderr: $e.msg} }
    if $r.exit_code != 0 { print -e $"homun-msg send ($to) ($name) failed: ($r.stderr | str trim)" }
}

# One fixed line for `to` (the manager by default) on the bus
export def alarm-to [to: string, name: string, msg: string] { bus-send $to $name $msg }

# One fixed line for the manager
export def alarm [name: string, msg: string] { alarm-to manager $name $msg }

# Why the image or the containers are being changed right now, or null: update/state says
# `running` (for under 20 minutes), or a claude-update that builds or recreates is in flight
export def updating []: nothing -> any {
    let state = $env.HOME | path join claude .services update state
    if ($state | path exists) {
        let w = open --raw $state | str trim | split row " "
        if ($w | first) == running and (age ($w | get -o 1 | default "0" | into int)) < 1200 { return "an update is running" }
    }
    if (^pgrep -f 'bin/[c]laude-update (sync|recreate|retry|rollback)' | complete).exit_code == 0 { return "a claude-update process is running" }
    null
}
