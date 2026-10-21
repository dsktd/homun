# iproute2-style command words, like `ip addr add`: `<object> <verb> [args]`,
# where any unambiguous prefix of an object or verb stands for it
# (`c po ad 8080` is `c port add 8080`).

# The launcher's commands: object -> its verbs. An object with no verbs takes
# its arguments directly (`c clone <url>`); a bare object means its `show` verb.
export const OBJECTS = {
    container: [start stop restart build show]
    session: [attach replace show]
    shell: []
    mount: [add del show]
    port: [add del show]
    clone: []
    emacs: []
    usage: []
}

# Resolve `argv` against `grammar` (an OBJECTS-shaped record) into
# {object, verb, rest}; verb is null for an object without verbs, and the
# object is null for empty argv. Fails when a word is unknown or ambiguous.
export def resolve [grammar: record, argv: list<string>]: nothing -> record {
    if ($argv | is-empty) { return {object: null, verb: null, rest: []} }

    let object = pick "object" $argv.0 ($grammar | columns)
    let verbs = $grammar | get $object
    if ($verbs | is-empty) { return {object: $object, verb: null, rest: ($argv | skip 1)} }
    if ($argv | length) == 1 { return {object: $object, verb: show, rest: []} }

    {object: $object, verb: (pick $"verb of ($object)" $argv.1 $verbs), rest: ($argv | skip 2)}
}

# The one candidate `word` names: an exact match, else the only one it prefixes
def pick [kind: string, word: string, candidates: list<string>]: nothing -> string {
    if $word in $candidates { return $word }
    let found = $candidates | where {|c| $word != "" and ($c | str starts-with $word) }
    match ($found | length) {
        1 => ($found | first)
        0 => (error make {msg: $"unknown ($kind) '($word)', expected ($candidates | str join '|')"})
        _ => (error make {msg: $"ambiguous ($kind) '($word)': ($found | str join ', ')"})
    }
}
