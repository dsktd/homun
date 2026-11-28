#!/usr/bin/env nu
# Temporary (redesign M0.1, removed with M5): inventory of what the redesign must keep, and a
# caller grep. Output is deterministic: sorted, no timestamps.
#   nu cli/inventory.nu                 the snapshot as JSON (tests/golden/inventory.json)
#   nu cli/inventory.nu callers <word>  files and lines that mention <word>, outside tests
#   nu cli/inventory.nu loc             lines of code per area (changes with every commit)

const ROOT = path self | path expand | path dirname | path dirname

def files []: nothing -> list<string> {
    cd $ROOT
    ^git ls-files | lines | where {|f| ($f | path exists) and not ($f | str starts-with tests/) and $f != cli/inventory.nu and not ($f | str ends-with .lock) and not ($f | str ends-with .png) and not ($f | str ends-with .ttf) }
}

def grep-all [pattern: string]: nothing -> list<string> {
    cd $ROOT
    files | each {|f| try { open --raw $f | decode utf-8 | parse --regex $pattern | get capture0 } catch { [] } } | flatten | uniq | sort
}

# Roles with the fields that matter, from container/roles.json
def roles []: nothing -> list<any> {
    open ($ROOT | path join container roles.json) | transpose name v | sort-by name | each {|r| {name: $r.name, status: ($r.v.status? | default null), has_manifest: (open ($ROOT | path join roles roles.toml) | columns | any {|k| $k == $r.name })} }
}

# Request kinds of homun-host
def kinds []: nothing -> list<string> {
    let line = open --raw ($ROOT | path join bin homun-host) | lines | where {|l| $l | str starts-with 'const KINDS = ' } | first
    $line | parse --regex '\[(?<k>[^\]]*)\]' | get k.0 | split row ' ' | where {|k| $k != '' } | sort
}

# MCP tools: every entry of the Emacs API registry
def tools []: nothing -> list<string> {
    grep-all '\(homun-api-define "([^"]+)"'
}

# Alarm names written literally (alarm="x", "alarm": "x"); alarms built at run time are not seen
def topics []: nothing -> list<string> {
    grep-all '(?:alarm=|"alarm": ?)"([a-z][a-z0-9_-]+)"'
}

def main [] {
    {roles: (roles), request_kinds: (kinds), tools: (tools), topics: (topics)} | to json --indent 2
}

# Lines per area, so each milestone shows its delta
def "main loc" [] {
    cd $ROOT
    files | each {|f| {area: ($f | path split | first | if ($f | path split | length) == 1 { '.' } else { $in }), loc: (try { open --raw $f | decode utf-8 | lines | length } catch { 0 })} }
    | group-by area | transpose area rows | each {|g| {area: $g.area, loc: ($g.rows.loc | math sum)} } | sort-by area
}

# Where a word is used, one `file:line: text` per hit
def "main callers" [word: string] {
    cd $ROOT
    files | each {|f|
        try { open --raw $f | decode utf-8 | lines | enumerate | where {|l| $l.item | str contains $word } | each {|l| $"($f):($l.index + 1): ($l.item | str trim)" } } catch { [] }
    } | flatten | str join "\n"
}
