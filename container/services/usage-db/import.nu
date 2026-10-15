#!/usr/bin/env nu
# Load the samples statusline.sh appends to ~/.claude/usage.jsonl into SQLite
# (table `samples`, one column per field, unique on ts + session_id with a null
# session_id counting as ''). Only lines after the count recorded in `meta` are
# read; a shorter file starts over, and the unique index drops duplicates, so
# re-running is always safe.
#
# Transcripts: every API message Claude Code writes to ~/.claude/projects/
# <dir>/<session>.jsonl (and <session>/subagents/agent-<id>.jsonl, where
# agent_id is set) goes into `messages` with its four token counts, keyed on the
# API message id: a streamed message is written as one record per content block,
# each repeating the usage, so the id (not the record uuid) is what makes
# re-imports idempotent. Each file resumes from its line count in `transcripts`
# and is skipped while its size and mtime are unchanged. `nu import.nu transcript
# <file>` imports one file (the hook); `main` walks the projects directory.
#
# Views for the readers (serve.py, bin/claude-usage), all days in UTC:
# `samples_left` turns the used percentages into percent left; `cost_deltas`
# turns the cumulative per-session cost_usd into the cost of each sample (a drop
# means Claude was resumed and started counting again, so the sample's whole
# value is new); `cost_per_day` sums those by day. `message_costs` prices each
# message with `prices` (USD per million tokens by model family, rewritten from
# PRICES on every run, so editing that table is enough): the longest family
# prefix of the model whose `since` is not after the message. `budget_deltas`
# is how many points of the 5-hour window each sample used up since the one
# before it, whichever session that was (the window is shared by all sessions,
# so it is attributed to the session the status line redrew for); a drop is the
# window resetting and is left out.

# usage.jsonl field -> SQLite column type
const COLUMNS = {
    ts: "integer not null", session_id: text, model: text,
    five_hour_used: real, five_hour_resets_at: integer, seven_day_used: real, seven_day_resets_at: integer,
    context_used_percentage: real, context_window_size: integer, total_input_tokens: integer, total_output_tokens: integer,
    cost_usd: real, duration_ms: integer, lines_added: integer, lines_removed: integer, version: text, cwd: text,
}

# transcript record field -> messages column type
const MESSAGE_COLUMNS = {
    id: "text primary key", uuid: text, ts: "integer not null", session_id: text, agent_id: text, agent_type: text,
    model: text, input_tokens: integer, output_tokens: integer, cache_creation_input_tokens: integer, cache_read_input_tokens: integer,
    cache_creation_1h_input_tokens: integer, cwd: text, version: text,
}

# USD per million tokens by model family (a prefix of the model id) from a day
# (UTC) on; add a row with a later `since` to change a price from then on.
# cache_write is a 5-minute cache write (1.25x input), cache_write_1h a 1-hour
# one (2x), which is what Claude Code uses.
const PRICES = [
    [family since input output cache_write cache_write_1h cache_read];
    [claude-fable-5-1 "2026-01-01" 10.0 50.0 12.5 20.0 0.25]
    [claude-fable-5 "2026-01-01" 10.0 50.0 12.5 20.0 1.0]
    [claude-opus-5-5 "2026-01-01" 4.0 20.0 5.0 8.0 0.2]
    [claude-opus-5 "2026-01-01" 5.0 25.0 6.25 10.0 0.5]
    [claude-opus-4 "2025-01-01" 5.0 25.0 6.25 10.0 0.5]
    [claude-sonnet-5-5 "2026-01-01" 2.0 10.0 2.5 4.0 0.2]
    [claude-sonnet-5 "2026-01-01" 2.0 10.0 2.5 4.0 0.2]
    [claude-sonnet-4 "2025-01-01" 3.0 15.0 3.75 6.0 0.3]
    [claude-haiku-5-5 "2026-01-01" 0.1 0.5 0.125 0.2 0.01]
    [claude-haiku-4 "2025-01-01" 1.0 5.0 1.25 2.0 0.1]
]

const HERE: string = path self | path dirname

const VIEWS = {
    samples_left: "select ts, session_id, model, cost_usd, cwd,
        max(0, 100 - five_hour_used) five_hour_left, max(0, 100 - seven_day_used) seven_day_left,
        max(0, 100 - context_used_percentage) context_left
        from samples"
    cost_deltas: "select ts, session_id, model, cost_usd,
        case when prev is null or cost_usd < prev then cost_usd else cost_usd - prev end delta
        from (select ts, session_id, model, cost_usd, lag(cost_usd) over (partition by session_id order by ts) prev
              from samples where cost_usd is not null)"
    cost_per_day: "select date(ts, 'unixepoch') day, count(distinct session_id) sessions, sum(delta) cost_usd
        from cost_deltas group by day"
    budget_deltas: "select ts, session_id, model, five_hour_used, five_hour_used - prev delta
        from (select ts, session_id, model, five_hour_used, lag(five_hour_used) over (order by ts, rowid) prev
              from samples where five_hour_used is not null)
        where prev is not null and five_hour_used >= prev"
    message_costs: "select m.*, p.family, p.since,
        (m.input_tokens * p.input + m.output_tokens * p.output
         + (m.cache_creation_input_tokens - m.cache_creation_1h_input_tokens) * p.cache_write
         + m.cache_creation_1h_input_tokens * p.cache_write_1h + m.cache_read_input_tokens * p.cache_read) / 1e6 cost_usd
        from messages m left join prices p on p.rowid = (
            select rowid from prices where m.model like family || '%' and since <= date(m.ts, 'unixepoch')
            order by length(family) desc, since desc limit 1)"
}

# An SQL literal for a value
def literal []: any -> string {
    match ($in | describe) {
        "nothing" => "NULL"
        "string" => $"'($in | str replace --all "'" "''")'"
        "bool" => (if $in { "1" } else { "0" })
        _ => ($in | into string)
    }
}

def sql [db: path, query: string, --params (-p): record = {}]: nothing -> table {
    open $db | query db $query -p $params
}

# Insert records (the named columns of each) in chunks, ignoring key conflicts
def insert-rows [db: path, table: string, names: list<string>, rows: table] {
    for chunk in ($rows | chunks 500) {
        let values = $chunk | each {|r| $"\(($names | each {|c| $r | get -o $c | literal } | str join ', '))" } | str join ",\n"
        sql $db $"insert or ignore into ($table) \(($names | str join ', ')) values ($values)" | ignore
    }
}

def epoch-secs []: datetime -> int {
    $in | into int | $in / 1_000_000_000 | math floor
}

# Tables, index and views; also migrates databases written by earlier versions
def prepare [db: path] {
    if not ($db | path exists) {
        # query db needs an existing database file and into sqlite cannot declare a
        # primary key, so a throwaway table creates the file and meta is made properly
        [{x: 0}] | into sqlite $db -t bootstrap
        sql $db "create table meta (key text primary key, value integer)" | ignore
        sql $db "insert into meta values ('lines', 0)" | ignore
        sql $db "drop table bootstrap" | ignore
    }
    let columns = $COLUMNS | items {|name, type| $"($name) ($type)" } | str join ", "
    sql $db $"create table if not exists samples \(($columns))" | ignore
    sql $db "create table if not exists meta (key text primary key, value integer)" | ignore
    let columns = $MESSAGE_COLUMNS | items {|name, type| $"($name) ($type)" } | str join ", "
    sql $db $"create table if not exists messages \(($columns))" | ignore
    sql $db "create table if not exists transcripts (path text primary key, offset integer, head text)" | ignore
    sql $db "create table if not exists prices (family text, since text, input real, output real, cache_write real, cache_write_1h real, cache_read real, primary key (family, since))" | ignore

    # meta without the primary key (earlier versions created it with into sqlite) gathered one row per run
    let meta = sql $db "select sql from sqlite_master where name = 'meta'" | get 0.sql
    if not ($meta =~ '(?i)primary key') {
        sql $db "create table meta_pk (key text primary key, value integer)" | ignore
        sql $db "insert into meta_pk select key, max(value) from meta group by key" | ignore
        sql $db "drop table meta" | ignore
        sql $db "alter table meta_pk rename to meta" | ignore
    }
    # earlier versions only had unique (ts, session_id), which lets null sessions through
    sql $db "delete from samples where rowid not in (select min(rowid) from samples group by ts, ifnull(session_id, ''))" | ignore
    sql $db "create unique index if not exists samples_key on samples (ts, ifnull(session_id, ''))" | ignore
    for v in ($VIEWS | items {|name, body| {name: $name, body: $body} }) {
        sql $db $"drop view if exists ($v.name)" | ignore
        sql $db $"create view ($v.name) as ($v.body)" | ignore
    }
}

# Bring `prices` in line with PRICES, row by row so readers never see it empty
def refresh-prices [db: path] {
    let keys = $PRICES | each {|p| $"\('($p.family)', '($p.since)')" } | str join ", "
    sql $db $"delete from prices where \(family, since) not in \(($keys))" | ignore
    for p in $PRICES {
        sql $db "insert or replace into prices values (:family, :since, :input, :output, :cache_write, :cache_write_1h, :cache_read)" -p $p | ignore
    }
}

def import-samples [jsonl: path, db: path] {
    let lines = if ($jsonl | path exists) { open --raw $jsonl | lines } else { [] }
    let done = sql $db "select max(value) value from meta where key = 'lines'" | get -o 0.value | default 0
    let start = if ($lines | length) < $done { 0 } else { $done }
    let rows = $lines
    | skip $start
    | where ($it | str trim | is-not-empty)
    | each { from json }
    | where ts? != null

    let before = sql $db "select count(*) n from samples" | get 0.n
    insert-rows $db samples ($COLUMNS | columns) $rows
    sql $db $"insert or replace into meta values \('lines', ($lines | length))" | ignore
    let after = sql $db "select count(*) n from samples" | get 0.n
    print $"($db): ($after - $before) new samples, ($after) in total \(($lines | length) lines read)"
}

# The messages row of an assistant transcript record, or null
def message-row []: record -> any {
    let r = $in
    let u = $r.message?.usage?
    if $r.type? != "assistant" or $u == null or $r.timestamp? == null { return null }
    {
        id: ($r.message.id? | default $r.uuid?)
        uuid: $r.uuid?
        ts: ($r.timestamp | into datetime | epoch-secs)
        session_id: $r.sessionId?
        agent_id: $r.agentId?
        agent_type: $r.attributionAgent?
        model: $r.message.model?
        input_tokens: ($u.input_tokens? | default 0)
        output_tokens: ($u.output_tokens? | default 0)
        cache_creation_input_tokens: ($u.cache_creation_input_tokens? | default 0)
        cache_read_input_tokens: ($u.cache_read_input_tokens? | default 0)
        cache_creation_1h_input_tokens: ($u.cache_creation?.ephemeral_1h_input_tokens? | default 0)
        cwd: $r.cwd?
        version: $r.version?
    }
}

# Import the bytes of one transcript after the offset recorded for it (only the
# whole lines); a file that shrank or whose first line changed (rewritten) is
# read from the start
def import-transcript [file: path, db: path] {
    let file = $file | path expand
    let size = ls -l $file | get 0.size | into int
    let head = ^head -c 1024 $file | into binary | hash md5
    let seen = sql $db "select offset, head from transcripts where path = :p" -p {p: $file} | get -o 0
    let start = if $seen == null or $size < $seen.offset or $head != $seen.head { 0 } else { $seen.offset }
    if $size == $start { return }

    let text = ^tail -c +($start + 1) $file | into binary | decode utf-8 # as a string the trailing newline would be stripped
    let end = $text | str index-of --end "\n" # str index-of and str substring count bytes
    if $end < 0 { return }
    let text = $text | str substring 0..$end
    let rows = $text
    | lines
    | where ($it | str contains '"assistant"')
    | each { try { from json } catch { null } }
    | compact
    | each { message-row }
    | compact
    insert-rows $db messages ($MESSAGE_COLUMNS | columns) $rows
    sql $db "insert or replace into transcripts values (:p, :offset, :head)" -p {p: $file, offset: ($start + $end + 1), head: $head} | ignore
}

# Every transcript under a projects directory: <session>.jsonl and its subagents
def transcripts [projects: path]: nothing -> list<path> {
    if not ($projects | path exists) { return [] }
    glob ($projects | path join "*" "*.jsonl") | append (glob ($projects | path join "*" "*" subagents "*.jsonl"))
}

# Run an import step, reporting the messages it added
def report [db: path, what: string, body: closure] {
    let before = sql $db "select count(*) n from messages" | get 0.n
    do $body
    let after = sql $db "select count(*) n from messages" | get 0.n
    print $"($db): ($after - $before) new messages, ($after) in total \(($what))"
}

def main [
    jsonl?: path # Samples file; defaults to ~/.claude/usage.jsonl
    db?: path # Database; defaults to usage.sqlite next to this script
    --projects: path # Transcripts root; defaults to ~/.claude/projects
] {
    let jsonl = $jsonl | default ($env.HOME | path join .claude usage.jsonl)
    let db = $db | default ($HERE | path join usage.sqlite)
    let projects = $projects | default ($env.HOME | path join .claude projects)
    prepare $db
    refresh-prices $db
    import-samples $jsonl $db
    let files = transcripts $projects
    report $db $"($files | length) transcripts" { for f in $files { import-transcript $f $db } }
}

# Import one transcript file (what the Stop/SubagentStop/SessionEnd hook runs)
def "main transcript" [
    file: path # A <session>.jsonl or subagents/agent-<id>.jsonl
    db?: path # Database; defaults to usage.sqlite next to this script
] {
    let db = $db | default ($HERE | path join usage.sqlite)
    prepare $db
    report $db $file { import-transcript $file $db }
}
