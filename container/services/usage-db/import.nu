#!/usr/bin/env nu
# Load the samples statusline.sh appends to ~/.claude/usage.jsonl into SQLite
# (table `samples`, one column per field, unique on ts + session_id with a null
# session_id counting as ''). Only lines after the count recorded in `meta` are
# read; a shorter file starts over, and the unique index drops duplicates, so
# re-running is always safe.
#
# Views for the readers (serve.py, bin/claude-usage), all days in UTC:
# `samples_left` turns the used percentages into percent left; `cost_deltas`
# turns the cumulative per-session cost_usd into the cost of each sample (a drop
# means Claude was resumed and started counting again, so the sample's whole
# value is new); `cost_per_day` sums those by day.

# usage.jsonl field -> SQLite column type
const COLUMNS = {
    ts: "integer not null", session_id: text, model: text,
    five_hour_used: real, five_hour_resets_at: integer, seven_day_used: real, seven_day_resets_at: integer,
    context_used_percentage: real, context_window_size: integer, total_input_tokens: integer, total_output_tokens: integer,
    cost_usd: real, duration_ms: integer, lines_added: integer, lines_removed: integer, version: text, cwd: text,
}

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

def sql [db: path, query: string]: nothing -> table {
    open $db | query db $query
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

def main [
    jsonl?: path # Samples file; defaults to ~/.claude/usage.jsonl
    db?: path # Database; defaults to usage.sqlite next to this script
] {
    let jsonl = $jsonl | default ($env.HOME | path join .claude usage.jsonl)
    let db = $db | default ($HERE | path join usage.sqlite)
    prepare $db

    let lines = if ($jsonl | path exists) { open --raw $jsonl | lines } else { [] }
    let done = sql $db "select max(value) value from meta where key = 'lines'" | get -o 0.value | default 0
    let start = if ($lines | length) < $done { 0 } else { $done }
    let names = $COLUMNS | columns
    let rows = $lines
    | skip $start
    | where ($it | str trim | is-not-empty)
    | each { from json }
    | where ts? != null
    | each {|r| $names | each {|c| $r | get -o $c | literal } | str join ", " }

    let before = sql $db "select count(*) n from samples" | get 0.n
    for chunk in ($rows | chunks 500) {
        let values = $chunk | each { $"\(($in))" } | str join ",\n"
        sql $db $"insert or ignore into samples \(($names | str join ', ')) values ($values)" | ignore
    }
    sql $db $"insert or replace into meta values \('lines', ($lines | length))" | ignore
    let after = sql $db "select count(*) n from samples" | get 0.n
    print $"($db): ($after - $before) new samples, ($after) in total \(($lines | length) lines read)"
}
