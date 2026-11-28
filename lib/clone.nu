use need.nu

export def --env main [bare_dir: path, url: string, name?: string]: nothing -> path {
    let name = $name | default ($url | str trim --right --char '/' | path basename | str replace --regex '\.git$' '')

    if $name in ['' '.' '..'] or ($name | path basename) != $name {
        error make { msg: $"invalid repo name '($name)'" }
    }

    let repo = $bare_dir | path expand | path join $"($name).git"

    if ($repo | path exists) {
        error make { msg: $"($repo) already exists" }
    }

    need git
    git clone --bare -- $url $repo
    git -C $repo config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    git -C $repo fetch origin

    $repo
}
