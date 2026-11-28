//! `homund sched next <cron> <epoch> | fires <table.json> <from> <to>`: the scheduler's cron
//! arithmetic (what `Cron` in container/services/scheduler/serve.py does), in local time.
//! `fires` lists, one `epoch name` line each, every fire of the enabled rows of a table between
//! two instants, as a scheduler that never went down would deliver them.

use std::collections::BTreeSet;
use std::process::ExitCode;

use chrono::Datelike;
use chrono::Duration;
use chrono::Local;
use chrono::NaiveDateTime;
use chrono::TimeZone;
use chrono::Timelike;
use serde_json::Value;

const RANGES: [(u32, u32); 5] = [(0, 59), (0, 23), (1, 31), (1, 12), (0, 7)];
const LOOK_AHEAD: i64 = 8 * 366 * 86400;

pub struct Cron {
    minutes: BTreeSet<u32>,
    hours: BTreeSet<u32>,
    dom: BTreeSet<u32>,
    months: BTreeSet<u32>,
    dow: BTreeSet<u32>,
    either_day: bool,
}

fn field(
    token: &str,
    (lo, hi): (u32, u32),
) -> Result<BTreeSet<u32>, String> {
    let bad = || format!("bad field {token:?}, allowed {lo}-{hi}");
    let mut values = BTreeSet::new();
    for item in token.split(',') {
        let (span, step) = match item.split_once('/') {
            Some((span, step)) => (span, Some(step.parse::<u32>().map_err(|_| bad())?)),
            None => (item, None),
        };
        let (first, last) = if span == "*" {
            (lo, hi)
        } else if let Some((a, b)) = span.split_once('-') {
            (a.parse().map_err(|_| bad())?, b.parse().map_err(|_| bad())?)
        } else {
            let first: u32 = span.parse().map_err(|_| bad())?;
            (first, if step.is_some() { hi } else { first })
        };
        let step = step.unwrap_or(1);
        if step < 1 || !(lo <= first && first <= last && last <= hi) {
            return Err(bad());
        }
        values.extend((first..=last).step_by(step as usize));
    }
    Ok(values)
}

fn wall(ts: i64) -> NaiveDateTime {
    Local.timestamp_opt(ts, 0).single().map_or_else(
        || chrono::DateTime::UNIX_EPOCH.naive_utc(),
        |t| t.naive_local(),
    )
}

impl Cron {
    pub fn parse(expr: &str) -> Result<Self, String> {
        let fields: Vec<&str> = expr.split_whitespace().collect();
        if fields.len() != 5 {
            return Err(format!("needs 5 fields, got {}: {expr:?}", fields.len()));
        }
        let mut sets = Vec::new();
        for (token, range) in fields.iter().zip(RANGES) {
            sets.push(field(token, range)?);
        }
        let [minutes, hours, dom, months, dow]: [BTreeSet<u32>; 5] =
            sets.try_into().map_err(|_| "unreachable")?;
        Ok(Self {
            minutes,
            hours,
            dom,
            months,
            dow: dow.into_iter().map(|d| d % 7).collect(),
            either_day: !fields[2].starts_with('*') && !fields[4].starts_with('*'),
        })
    }

    fn day_matches(
        &self,
        day: NaiveDateTime,
    ) -> bool {
        if !self.months.contains(&day.month()) {
            return false;
        }
        let dom = self.dom.contains(&day.day());
        let dow = self.dow.contains(&day.weekday().num_days_from_sunday());
        if self.either_day {
            dom || dow
        } else {
            dom && dow
        }
    }

    fn matches(
        &self,
        w: NaiveDateTime,
    ) -> bool {
        self.minutes.contains(&w.minute()) && self.hours.contains(&w.hour()) && self.day_matches(w)
    }

    /// Whether `t` is the second pass over a wall-clock hour (a one-hour fall-back).
    fn repeated(t: i64) -> bool {
        wall(t) == wall(t - 3600)
    }

    fn fires_at(
        &self,
        t: i64,
    ) -> bool {
        let w = wall(t);
        if self.matches(w) {
            return self.hours.len() == 24 || !Self::repeated(t);
        }
        let skipped = (w - wall(t - 60)).num_minutes();
        skipped > 1 && (1..skipped).any(|back| self.matches(w - Duration::minutes(back)))
    }

    /// The first fire strictly after `ts`, or None if there is none in 8 years.
    pub fn next_after(
        &self,
        ts: i64,
    ) -> Option<i64> {
        let mut t = ts.div_euclid(60) * 60 + 60;
        let limit = ts + LOOK_AHEAD;
        while t <= limit {
            let w = wall(t);
            if self.fires_at(t) {
                return Some(t);
            }
            if !self.day_matches(w) {
                let midnight = Local
                    .from_local_datetime(&(w.date() + Duration::days(1)).and_hms_opt(0, 0, 0)?)
                    .earliest()
                    .map_or(0, |m| m.timestamp());
                t = (t + 60).max(midnight);
            } else if !self.hours.contains(&w.hour()) {
                t += 900 - t.rem_euclid(900);
            } else {
                t += 60;
            }
        }
        None
    }
}

/// Every fire `(epoch, name)` of the enabled rows of `table` in (`from`, `to`], by time then row.
pub fn fires(
    table: &Value,
    from: i64,
    to: i64,
) -> Result<Vec<(i64, String)>, String> {
    let mut out = Vec::new();
    for row in table.as_array().ok_or("the table is not a list")? {
        let text = |k: &str| row.get(k).and_then(Value::as_str);
        let (Some(name), Some(expr)) = (text("name"), text("cron")) else {
            continue;
        };
        let Ok(cron) = Cron::parse(expr) else {
            continue;
        };
        if row.get("enabled") == Some(&Value::Bool(false)) {
            continue;
        }
        let mut at = from;
        while let Some(next) = cron.next_after(at).filter(|n| *n <= to) {
            out.push((next, name.to_owned()));
            at = next;
        }
    }
    out.sort_by_key(|(t, _)| *t);
    Ok(out)
}

pub fn run(args: &[String]) -> ExitCode {
    let result = match args.iter().map(String::as_str).collect::<Vec<_>>()[..] {
        ["next", expr, after] => Cron::parse(expr).and_then(|c| {
            let after = after.parse().map_err(|_| "epoch is a number".to_owned())?;
            Ok(c.next_after(after).map_or("none".into(), |t| t.to_string()))
        }),
        ["fires", file, from, to] => (|| {
            let table = std::fs::read_to_string(file).map_err(|e| e.to_string())?;
            let table: Value = serde_json::from_str(&table).map_err(|e| e.to_string())?;
            let num = |s: &str| s.parse().map_err(|_| "from and to are epochs".to_owned());
            let lines = fires(&table, num(from)?, num(to)?)?;
            Ok(lines
                .iter()
                .map(|(t, n)| format!("{t} {n}"))
                .collect::<Vec<_>>()
                .join("\n"))
        })(),
        ["run", mode @ ("shadow" | "live")] => {
            return match crate::schedd::serve(mode == "live") {
                Ok(()) => ExitCode::SUCCESS,
                Err(err) => {
                    eprintln!("homund sched: {err}");
                    ExitCode::FAILURE
                }
            };
        }
        ["diff", real, shadow] => {
            return match crate::scheddiff::run(real.as_ref(), shadow.as_ref()) {
                Ok(clean) => ExitCode::from(u8::from(!clean)),
                Err(err) => {
                    eprintln!("homund sched: {err}");
                    ExitCode::from(2)
                }
            };
        }
        _ => {
            println!(
                "homund sched next <cron> <epoch> | fires <table.json> <from> <to> | run shadow|live | diff <real dir> <shadow dir>"
            );
            return ExitCode::SUCCESS;
        }
    };
    match result {
        Ok(text) => {
            if !text.is_empty() {
                println!("{text}");
            }
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("homund sched: {err}");
            ExitCode::FAILURE
        }
    }
}
