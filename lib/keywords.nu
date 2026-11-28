# iproute2-style options: positional `<keyword> <value>` pairs after a
# command's arguments, like `ip addr add ... dev eth0 scope link`.

# Parse `args` against `accepted`, a record of keyword -> allowed values whose
# first value is the default, into a record of keyword -> value. An empty value
# list accepts any value, with null as the default.
export def parse [args: list<string>, accepted: record]: nothing -> record {
    mut result = $accepted | items { |key, values| {($key): ($values | get -o 0)} } | into record
    mut rest = $args
    let keys = $accepted | columns

    while ($rest | is-not-empty) {
        let key = $rest | first
        if $key not-in $keys {
            error make {msg: $"unknown option '($key)', expected (usage $accepted)"}
        }
        let values = $accepted | get $key
        if ($rest | length) < 2 {
            error make {msg: $"'($key)' needs a value: ($values | str join '|')"}
        }
        let value = $rest | get 1
        if ($values | is-not-empty) and $value not-in $values {
            error make {msg: $"'($key)' must be one of ($values | str join '|'), not '($value)'"}
        }
        $result = $result | merge {($key): $value}
        $rest = $rest | skip 2
    }

    $result
}

def usage [accepted: record]: nothing -> string {
    $accepted | items { |key, values| $"[($key) (if ($values | is-empty) { '<value>' } else { $values | str join '|' })]" } | str join ' '
}
