# The host config: one JSON file for the values that are specific to this machine.
# $HOMUN_CONFIG, else ~/.config/claude/config.json; every key is optional and the
# marker files next to it still work. Keys: user, settop, tracker_file,
# treebundel_repo, cpuset, gpu, kvm, roles (list of role keys), ports (list of {host container proto from scope}),
# cockpit ({config: <directory of the user's own Emacs configuration, loaded over the cockpit's plain one; a Doom directory makes it a Doom build>}).
# Mounted read-only at /run/claude-config.json so container tools read the same file.

export def file []: nothing -> path {
    $env.HOMUN_CONFIG? | default ($env.HOME | path join .config claude config.json)
}

# Whether this runs inside a container (Podman's marker file; HOMUN_CONTAINERENV overrides its path)
export def in-container []: nothing -> bool {
    $env.HOMUN_CONTAINERENV? | default /run/.containerenv | path exists
}

export def load []: nothing -> record {
    let f = file
    if ($f | path exists) { open $f } else { {} }
}

export def value [key: string, fallback: any]: nothing -> any {
    load | get --optional $key | default $fallback
}
