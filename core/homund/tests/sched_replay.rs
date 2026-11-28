//! Alarm replay: the week of the 2026 fall-back (28 Oct to 4 Nov, a US eastern-time DST zone) of the
//! scheduler's table fires exactly as it was logged, and as serve.py's `Cron` computes it.

use std::process::Command;

use homund::sched::fires;
use serde_json::Value;

fn fixture() -> Value {
    let text = include_str!("fixtures/sched-week.json");
    serde_json::from_str(text).unwrap()
}

fn run_new() -> Vec<(i64, String)> {
    let f = fixture();
    let (from, to) = (f["from"].as_i64().unwrap(), f["to"].as_i64().unwrap());
    fires(&f["table"], from, to).unwrap()
}

#[test]
fn the_week_matches_its_log() {
    let log: Vec<(i64, String)> = fixture()["log"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| (e[0].as_i64().unwrap(), e[1].as_str().unwrap().to_owned()))
        .collect();
    assert_eq!(run_new(), log);
}

#[test]
fn the_week_matches_serve_py() {
    let serve = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../container/services/scheduler"
    );
    let script = r#"
import json, sys
sys.path.insert(0, sys.argv[1])
import serve
f = json.load(open(sys.argv[2]))
out = []
for row in f["table"]:
    c, at = serve.Cron(row["cron"]), f["from"]
    while (n := c.next_after(at)) is not None and n <= f["to"]:
        out.append((int(n), row["name"]))
        at = n
for t, n in sorted(out, key=lambda x: x[0]):
    print(t, n)
"#;
    let fixture = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/sched-week.json"
    );
    let Ok(old) = Command::new("python3")
        .args(["-c", script, serve, fixture])
        .env("TZ", "EST5EDT,M3.2.0,M11.1.0")
        .output()
    else {
        return;
    };
    assert!(
        old.status.success(),
        "{}",
        String::from_utf8_lossy(&old.stderr)
    );
    let old: Vec<String> = String::from_utf8(old.stdout)
        .unwrap()
        .lines()
        .map(str::to_owned)
        .collect();
    let new: Vec<String> = run_new().iter().map(|(t, n)| format!("{t} {n}")).collect();
    assert_eq!(old, new);
}
