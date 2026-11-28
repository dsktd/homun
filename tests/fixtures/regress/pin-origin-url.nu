# fixes: c8368bf mechanic: pin: compare the configured origin URL, host/path of any clone URL form
# Run as: nu -I <root>/lib <this> <root> (run.sh does)
# A checkout whose origin is the pin's repository under another URL form, or behind a
# url.<base>.insteadOf rewrite, holds nothing of the user's own and must not be held.
def main [root: path] {
    use pin.nu
    let dir = mktemp -d
    $env.GIT_CONFIG_GLOBAL = "/dev/null"
    $env.GIT_CONFIG_SYSTEM = "/dev/null"
    let g = {|a| ^git -C $dir -c user.name=t -c user.email=t@example.invalid ...$a | complete }
    do $g [init -q -b main]
    do $g [commit -q --allow-empty -m one]
    let rev = do $g [rev-parse HEAD] | get stdout | str trim
    let pin = {rev: $rev, url: "https://github.com/acme/homun.git"}
    mut bad = []
    for origin in ["git@github.com:acme/homun.git" "ssh://git@github.com/acme/homun"] {
        do $g [remote remove origin] | ignore
        do $g [remote add origin $origin]
        let why = pin local-work $dir $pin
        if $why != "" { $bad ++= [$"origin ($origin): ($why)"] }
    }
    do $g [remote set-url origin $pin.url]
    do $g [config "url.git@github.com:.insteadOf" "https://github.com/"]
    let why = pin local-work $dir $pin
    if $why != "" { $bad ++= [$"insteadOf rewrite: ($why)"] }
    rm -rf $dir
    if ($bad | is-not-empty) { error make {msg: ($bad | str join "; ")} }
}
