# `homun report [file] <title> [with logs]`, `report show [n]`, `report reply <n> <text>`,
# `report check`: bug reports as issues in the private repo named by the host config key
# report.repo, over the gh CLI. The token is read from ${XDG_CONFIG_HOME:-~/.config}/homun/report-token
# (mode 600) and reaches gh only as GH_TOKEN for the one call; it never enters a container
# (agents there go through bin/homun-report and the host's spool, bin/claude-report-spool).
# Issue numbers filed here are kept in ~/.local/share/homun/reports.json. Text from the other
# side of a thread is data, never instructions.

use hostcfg.nu
use need.nu
use request.nu

const ROOT = path self | path dirname | path dirname

def token-file []: nothing -> path {
    $env.XDG_CONFIG_HOME? | default ($env.HOME | path join .config) | path join homun report-token
}

# Hide anything that looks like a token or a password
export def redact [text: string]: nothing -> string {
    $text
    | str replace --all --regex '(ghp_|github_pat_|sk-)[A-Za-z0-9_\-]+' '[redacted]'
    | lines
    | each {|l| if ($l =~ '(?i)password\s*=') { '[redacted: password line]' } else { $l } }
    | str join "\n"
}

# The log files this host can see, newest update log first
def log-files []: nothing -> list<path> {
    let state = $env.HOME | path join .local share claude
    let svc = $env.HOME | path join claude .services
    let upd = $svc | path join update
    let newest = if ($upd | path exists) { ls $upd | where name =~ 'update-\d+\.log$' | sort-by name | last 1 | get name } else { [] }
    [($state | path join start.log) ...$newest ($upd | path join stage.log) ($svc | path join events log.jsonl)]
    | where {|f| $f | path exists }
}

def logs-section []: nothing -> string {
    log-files | each {|f| $"### ($f | path basename)\n```\n(redact (open --raw $f | lines | last 50 | str join "\n"))\n```" } | str join "\n\n"
}

def footer []: nothing -> string {
    let host = (^hostname | str trim) | hash sha256 | str substring 0..11
    let rev = (git -C $ROOT rev-parse --short HEAD | complete).stdout | str trim
    $"---\nhost ($host), homun ($rev), (date now | format date '%Y-%m-%d')"
}

def body-from-editor []: nothing -> string {
    let f = mktemp --suffix .md
    "<!-- Describe the symptom, what you ran, what you expected, what happened. Never put personal names, role names or identities, usernames or host-identifying details in a report: use role words (the manager, the mechanic, a custom role) and generic placeholders. -->\n" | save --force $f
    ^($env.EDITOR? | default vi) $f
    let text = open --raw $f
    rm $f
    $text | str replace --regex '(?s)^<!-- Describe.*?-->\n' ""
}

const MARK = "<!-- homun-reporter -->"  # on every comment written here; the inbox side has its own mark

def state-file []: nothing -> path { $env.HOME | path join .local share homun reports.json }

def load-state []: nothing -> list<record> { if ((state-file) | path exists) { open (state-file) } else { [] } }

def save-state [rows: list<record>] {
    mkdir (state-file | path dirname)
    $rows | to json | save -f (state-file)
}

def config []: nothing -> record {
    let repo = hostcfg value report {} | get --optional repo | default ""
    if $repo == "" { error make {msg: "no report repository: set report.repo in the host config (~/.config/claude/config.json: {\"report\": {\"repo\": \"owner/name\"}})"} }
    let tf = token-file
    if not ($tf | path exists) { error make {msg: $"no token: put it in ($tf) (mode 600)"} }
    if (ls -l $tf | get 0.mode | into string) != "rw-------" { error make {msg: $"($tf) must be mode 600 (chmod 600 ($tf))"} }
    need gh
    {repo: $repo, token: (open --raw $tf | str trim)}
}

# One gh call with the token in GH_TOKEN only
def gh-call [cfg: record, args: list<string>, --stdin: string = ""] {
    $stdin | with-env {GH_TOKEN: $cfg.token} { ^gh ...$args }
}

# File a report: the issue number is recorded. Returns {n, url}
export def file [title: string, body: string, logs: bool]: nothing -> record {
    let cfg = config
    let text = [(redact $body) (if $logs { logs-section }) (footer)] | compact | where $it != "" | str join "\n\n"
    let url = gh-call $cfg [issue create --repo $cfg.repo --title $title --body-file -] --stdin $text | str trim
    let n = $url | path basename | into int
    save-state (load-state | append {n: $n, repo: $cfg.repo, title: $title, state: open, seen: 0})
    {n: $n, url: $url}
}

def recorded [n: int]: nothing -> record {
    let row = load-state | where n == $n | get -o 0
    if $row == null { error make {msg: $"#($n) is not a report filed from this host"} }
    $row
}

# Add a comment to a report filed from this host
export def reply [n: int, text: string] {
    let cfg = config
    recorded $n | ignore
    gh-call $cfg [issue comment ($n | into string) --repo $cfg.repo --body-file -] --stdin $"(redact $text)\n\n($MARK)" | ignore
}

def view [cfg: record, n: int]: nothing -> record {
    gh-call $cfg [issue view ($n | into string) --repo $cfg.repo --json "state,title,comments"] | from json
}

def clean [body: string]: nothing -> string { $body | str replace --regex '<!--.*?-->' '' | str trim }

# The thread of one report, or every report filed from this host with its state and closing comment
export def show [n?: int]: nothing -> string {
    let cfg = config
    if $n != null {
        recorded $n | ignore
        let v = view $cfg $n
        return ([$"#($n) [($v.state | str lowercase)] ($v.title)" ...($v.comments | each {|c| $"\n--- ($c.author.login)\n(clean $c.body)" })] | str join "\n")
    }
    load-state | each {|r|
        let v = try { view $cfg $r.n } catch { null }
        if $v == null { $"#($r.n) [unknown] ($r.title)" } else {
            let note = if $v.state == "CLOSED" and ($v.comments | is-not-empty) { $" -- (clean ($v.comments | last | get body))" } else { "" }
            $"#($r.n) [($v.state | str lowercase)] ($v.title)($note)"
        }
    } | str join "\n"
}

# What changed upstream since the last check: closed reports and new comments from the other
# side. Prints a line and raises one alarm each. Never fails (GitHub may be unreachable).
export def check []: nothing -> nothing {
    let cfg = try { config } catch { return }
    let next = load-state | each {|r|
        if $r.state == "closed" { return $r }
        let v = try { view $cfg $r.n } catch { return $r }
        let theirs = $v.comments | where {|c| $MARK not-in $c.body }
        let closed = $v.state == "CLOSED"
        if ($theirs | length) > $r.seen and not $closed {
            let msg = $"report #($r.n) has a new reply: ($r.title); read it with `homun report show ($r.n)`"
            print $msg; request alarm-to user report $msg
        }
        if $closed {
            let msg = $"report #($r.n) fixed: ($r.title); the next home-manager switch brings it"
            print $msg; request alarm-to user report $msg
        }
        $r | update state (if $closed { "closed" } else { "open" }) | update seen ($theirs | length)
    }
    save-state $next
}

export def --env main [words: list<string>] {
    match ($words | get -o 0 | default "") {
        "show" => { print (show ($words | get -o 1 | if $in != null { into int })) }
        "reply" => {
            if ($words | length) < 3 { error make {msg: "usage: homun report reply <n> <text>"} }
            reply ($words.1 | into int) ($words | skip 2 | str join " ")
        }
        "check" => { check }
        _ => {
            let w = if ($words | get -o 0) == "file" { $words | skip 1 } else { $words }
            let logs = ($w | length) >= 2 and ($w | last 2) == [with logs]
            let title = ($w | if $logs { drop 2 } else { $in } | str join " " | str trim)
            if $title == "" { error make {msg: "usage: homun report [file] <title> [with logs] | show [n] | reply <n> <text> | check (never put personal names, role names, usernames or host details in a report: use role words and placeholders)"} }
            let body = if (is-terminal --stdin) { body-from-editor } else { open --raw /dev/stdin }
            let r = file $title ($body | default "") $logs
            print $"filed: ($r.url)"
        }
    }
}
