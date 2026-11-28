# The pin: the launcher commit this host is meant to run. The host's configuration writes
# ${XDG_CONFIG_HOME:-~/.config}/homun/pin as {"rev": "<40 hex>", "url": "<clone url>"}; the host
# service (bin/homun-host) brings the checkout it runs from to that commit. A host without the
# file has no pin and its checkout is never moved.
#
# The checkout is only moved while nothing in it is the user's own work: no uncommitted change to a
# tracked file, and no commit that was never published. The published main is one parentless
# commit that is replaced at every publish, so ancestry cannot say what was published: a commit
# counts as published when it is reachable from the pinned commit, from the commit this code last
# moved the checkout to (homun-pin in its git directory), from a remote-tracking ref of origin or from anything such
# a ref pointed to before (its reflog). Comparing HEAD with origin/main alone called every older
# publish a local commit as soon as a fetch had moved origin/main on, and the checkout then stayed
# where it was for good.

export def file []: nothing -> path {
    ($env.XDG_CONFIG_HOME? | default ($env.HOME | path join .config)) | path join homun pin
}

# {rev, url}, or null when there is no pin or it is not one
export def read []: nothing -> any {
    let row = try { open --raw (file) | from json } catch { return null }
    let rev = try { $row.rev } catch { "" }
    let url = try { $row.url } catch { "" }
    if ($rev | describe) != string or not ($rev =~ '^[0-9a-f]{40}$') or ($url | describe) != string or $url == "" { return null }
    {rev: $rev, url: $url}
}

def git [dir: path, args: list<string>]: nothing -> record { ^git -C $dir ...$args | complete }

def out [dir: path, args: list<string>]: nothing -> string { git $dir $args | get stdout | str trim }

def is-commit [dir: path, rev: string]: nothing -> bool { (git $dir [cat-file -e $"($rev)^{commit}"]).exit_code == 0 }

# host/path of a clone URL, so the https, ssh:// and scp-like (git@host:path) forms of one
# repository compare equal
def plain-url [url: string]: nothing -> string {
    $url | str trim | str replace -r '/+$' '' | str replace -r '\.git$' ''
    | str replace -r '^[a-z][a-z0-9+.-]*://' '' | str replace -r '^[^@/]+@' ''
    | str replace -r '^([^/:]+):([^/0-9])' '$1/$2'
}

# The checkout's HEAD, or "" when it is not a git checkout
export def head [dir: path]: nothing -> string {
    let r = git $dir [rev-parse HEAD]
    if $r.exit_code == 0 { $r.stdout | str trim } else { "" }
}

# In the checkout's git directory: .git is a file (gitdir: ...) in a worktree, so ask git where
def record-file [dir: path]: nothing -> path {
    let p = out $dir [rev-parse --path-format=absolute --git-path homun-pin]
    if $p == "" { $dir | path join .git homun-pin } else { $p }
}

# Why the checkout must stay where it is, or "" when it holds nothing of the user's own
export def local-work [dir: path, pin: record]: nothing -> string {
    # The configured value: `remote get-url` applies the user's url.<base>.insteadOf rewrites
    let origin = out $dir [config --get remote.origin.url]
    if (plain-url $origin) != (plain-url $pin.url) { return $"its origin is not ($pin.url): a checkout that is run live keeps its commits" }
    if (out $dir [status --porcelain --untracked-files=no]) != "" { return "it has uncommitted changes" }
    let recorded = try { open --raw (record-file $dir) | str trim } catch { "" }
    let refs = out $dir [for-each-ref "--format=%(refname)" refs/remotes/origin] | lines
    let was = $refs | each {|r| out $dir [log -g --format=%H $r] | lines } | flatten
    let published = [$pin.rev $recorded ...$was] | uniq | where {|c| $c =~ '^[0-9a-f]{40}$' and (is-commit $dir $c) }
    let own = out $dir [rev-list HEAD --not ...$published ...$refs] | lines
    if ($own | is-empty) { "" } else { $"it has ($own | length) commit\(s) that were never published, newest ($own | first | str substring 0..11)" }
}

# Why the checkout may not act on the host, or null: published means HEAD is the pin, and clean
export def unpublished [dir: path]: nothing -> any {
    let pin = read
    if $pin == null { return "no pin: nothing is published" }
    if (head $dir) != $pin.rev { return $"HEAD is not the pinned ($pin.rev | str substring 0..6)" }
    if (out $dir [status --porcelain --untracked-files=no]) != "" { return "the checkout has uncommitted changes" }
    null
}

# Bring the checkout to the pin: {state, why, head}. state is
#   none     no pin file, or the directory is not a git checkout
#   current  HEAD is the pinned commit already
#   moved    HEAD was moved to it
#   held     the checkout holds the user's own work (why says what) and was left alone
#   failed   the pinned commit could not be fetched or checked out
# `force` moves over unpublished commits (they stay in the reflog), never over uncommitted changes.
export def apply [dir: path, force: bool = false]: nothing -> record {
    let pin = read
    let at = head $dir
    if $pin == null or $at == "" { return {state: none, why: (if $pin == null { "no pin" } else { $"($dir) is not a git checkout" }), head: $at} }
    if $at == $pin.rev {
        $pin.rev + "\n" | save -f (record-file $dir)
        return {state: current, why: "", head: $at}
    }
    let why = local-work $dir $pin
    if $why != "" and not ($force and ($why | str starts-with "it has ") and not ($why | str contains uncommitted)) {
        return {state: held, why: $why, head: $at}
    }
    # A publish replaces the remote's history, so the pin is fetched by its id; a remote that
    # refuses an id it no longer advertises may still hand it out with its refs
    if not (is-commit $dir $pin.rev) { git $dir [fetch -q origin $pin.rev] | ignore }
    if not (is-commit $dir $pin.rev) { git $dir [fetch -q origin] | ignore }
    if not (is-commit $dir $pin.rev) { return {state: failed, why: $"could not fetch ($pin.rev | str substring 0..11) from ($pin.url)", head: $at} }
    let r = git $dir [reset -q --hard $pin.rev]
    if $r.exit_code != 0 { return {state: failed, why: $"git reset failed: ($r.stderr | str trim | lines | last 1 | str join '')", head: (head $dir)} }
    $pin.rev + "\n" | save -f (record-file $dir)
    {state: moved, why: $"from ($at | str substring 0..11)", head: $pin.rev}
}
