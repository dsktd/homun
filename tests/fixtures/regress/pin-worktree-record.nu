# fixes: f4ebab8 mechanic: pin: keep homun-pin where git says, so a worktree checkout records its move
# Run as: nu -I <root>/lib <this> <root> (run.sh does)
# In a worktree .git is a file: recording the pinned commit must still work there.
def main [root: path] {
    use pin.nu
    let dir = mktemp -d
    $env.GIT_CONFIG_GLOBAL = "/dev/null"
    $env.GIT_CONFIG_SYSTEM = "/dev/null"
    $env.XDG_CONFIG_HOME = $dir | path join config
    let main = $dir | path join main
    let wt = $dir | path join wt
    ^git init -q -b main $main
    ^git -C $main -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m one
    ^git -C $main worktree add -q --detach $wt
    let rev = ^git -C $wt rev-parse HEAD | str trim
    mkdir ($env.XDG_CONFIG_HOME | path join homun)
    {rev: $rev, url: "https://github.com/acme/homun"} | to json | save (pin file)
    let r = try { pin apply $wt } catch {|e| {state: error, why: $e.msg} }
    let recorded = ^git -C $wt rev-parse --path-format=absolute --git-path homun-pin | str trim
    let ok = $r.state == current and ($recorded | path exists)
    rm -rf $dir
    if not $ok { error make {msg: $"apply in a worktree: ($r.state) ($r.why)"} }
}
