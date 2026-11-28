use store.nu

# homun.toml: the host's own state that `homun` writes and homund reads, ~/.config/homun/homun.toml
# ($HOMUN_TOML overrides): `[[mount]]` (path, mode), `[[port]]` (host, container, proto, from,
# scope), `gpu` and `kvm` (bools). Values the host config declares (config.json) are separate.

export def file []: nothing -> path {
    $env.HOMUN_TOML? | default ($env.HOME | path join .config homun homun.toml)
}

# The document; the first read after an upgrade writes it from the older files
# (mounts.nuon, ports.nuon, the gpu and kvm markers in ~/.config/claude) and renames those to
# <name>.migrated, so nothing is lost
export def load []: nothing -> record {
    if not (file | path exists) {
        if not (legacy | any {|f| $f | path exists }) { return {} }
        migrate
    }
    open (file)
}

def legacy []: nothing -> list<path> {
    [mounts.nuon ports.nuon gpu kvm] | each {|name| $env.HOME | path join .config claude $name }
}

export def read [key: string, fallback: any]: nothing -> any {
    load | get -o $key | default $fallback
}

export def write [key: string, value: any] {
    # Through a variable: piped straight from `open`, an empty list would vanish from the output
    let doc = load
    $doc | upsert $key $value | to toml | store (file)
}

def migrate [] {
    let old = $env.HOME | path join .config claude
    let nuon = {|name| let f = $old | path join $name; if ($f | path exists) { open --raw $f | from nuon | default [] } else { [] } }
    let marker = {|name| $old | path join $name | path exists }
    {mount: (do $nuon mounts.nuon), port: (do $nuon ports.nuon), gpu: (do $marker gpu), kvm: (do $marker kvm)}
    | to toml | store (file)
    for f in (legacy | where {|f| $f | path exists }) { mv $f $"($f).migrated" }
}
