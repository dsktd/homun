//! `homund sched diff <real dir> <shadow dir>`: the fires of the scheduler service (history.jsonl
//! of `real dir`) against what the shadow would have sent (history.jsonl of `shadow dir`), from the
//! time the shadow first ran (its `since` file). Manual fires are left out: only serve.py takes them.

use std::path::Path;

use serde_json::Value;

/// A fire counts as the same when the name matches and the times are this close (the shadow looks
/// at the clock more often than serve.py does).
const SLACK: i64 = 90;

#[derive(Debug, PartialEq)]
pub struct Fire {
    pub ts: i64,
    pub name: String,
    pub msg: String,
}

pub fn read(
    path: &Path,
    since: i64,
) -> Vec<Fire> {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    text.lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter(|r| r["manual"] != Value::Bool(true))
        .filter_map(|r| {
            Some(Fire {
                ts: r["ts"].as_i64().filter(|t| *t >= since)?,
                name: r["name"].as_str()?.to_owned(),
                msg: r["msg"].as_str().unwrap_or_default().to_owned(),
            })
        })
        .collect()
}

/// One line per difference, then a summary line; the bool is whether the two agree.
pub fn compare(
    real: &[Fire],
    shadow: &[Fire],
) -> (Vec<String>, bool) {
    let mut rest: Vec<&Fire> = shadow.iter().collect();
    let (mut lines, mut same) = (Vec::new(), 0);
    for r in real {
        let hit = rest
            .iter()
            .position(|s| s.name == r.name && (s.ts - r.ts).abs() <= SLACK);
        match hit.map(|i| rest.remove(i)) {
            Some(s) if s.msg == r.msg => same += 1,
            Some(s) => lines.push(format!(
                "msg {} {}\n  real:   {}\n  shadow: {}",
                r.ts, r.name, r.msg, s.msg
            )),
            None => lines.push(format!("only-real {} {}", r.ts, r.name)),
        }
    }
    lines.extend(
        rest.iter()
            .map(|s| format!("only-shadow {} {}", s.ts, s.name)),
    );
    let clean = lines.is_empty();
    let verdict = if clean { "clean" } else { "DIFFERS" };
    lines.push(format!(
        "{verdict}: {same} fires agree, {} differ",
        lines.len()
    ));
    (lines, clean)
}

pub fn run(
    real: &Path,
    shadow: &Path,
) -> Result<bool, String> {
    let since = std::fs::read_to_string(shadow.join("since"))
        .map_err(|e| format!("{}/since: {e} (has the shadow run?)", shadow.display()))?
        .trim()
        .parse()
        .map_err(|_| "since is not an epoch".to_owned())?;
    let (lines, clean) = compare(
        &read(&real.join("history.jsonl"), since),
        &read(&shadow.join("history.jsonl"), since),
    );
    println!("{}", lines.join("\n"));
    Ok(clean)
}
