# Call the manager's Emacs through the constant form (homun-rpc), the call as arguments
# (container/emacs/homun-api.el), so nothing passed is evaluated as Lisp.

const SOCKET = [claude .services emacs socket]

def unescape []: string -> string {
    $in | str replace -a '\\' "\u{1}" | str replace -a '\"' '"' | str replace -a '\n' "\n" | str replace -a '\t' "\t" | str replace -a "\u{1}" '\'
}

# {code, body}: code 0 ok, 1 failed, 2 no server, 3 unknown entry, 4 invalid arguments, 5 timeout, 6 still starting
export def rpc [words: list<string>]: nothing -> record {
    let socket = $env.HOME | path join ...$SOCKET
    if not ($socket | path exists) {
        return {code: 2, body: $"no server at ($socket): `homun editor start`"}
    }
    let r = ^emacsclient -s $socket --eval '(homun-rpc)' ...$words | complete
    if $r.exit_code != 0 {
        return {code: 2, body: $"emacsclient failed: ($r.stderr | str trim)"}
    }
    let out = $r.stdout | str trim
    if not ($out | str starts-with '"') { return {code: 1, body: $"unexpected reply: ($out)"} }
    let text = $out | str substring 1..<(($out | str length) - 1) | unescape
    let head = $text | lines | first
    let body = $text | lines | skip 1 | str join "\n"
    if $head == "ok" { return {code: 0, body: $body} }
    let kind = $head | str replace 'err ' ''
    let code = match $kind { "unknown" => 3, "invalid" => 4, "timeout" => 5, "starting" => 6, _ => 1 }
    {code: $code, body: $"($kind): ($body)"}
}
