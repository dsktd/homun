//! The scheduler service against a stand-in world: delivery, forecast alarms, catchup, reload,
//! and the shadow diff; plus the forecast alarms against serve.py's own `ResetAlarms`.

use std::path::Path;
use std::path::PathBuf;
use std::process::Command;

use homund::alarms::ResetAlarms;
use homund::alarms::Window;
use homund::alarms::allowed;
use homund::alarms::message;
use homund::schedd::Ledger;
use homund::schedd::Scheduler;
use homund::schedd::World;
use homund::scheddiff::Fire;
use homund::scheddiff::compare;
use serde_json::Value;
use serde_json::json;

struct Fake {
    table: Value,
    forecast: Value,
    state: &'static str,
}

impl World for Fake {
    fn table(&mut self) -> Result<Value, String> {
        Ok(self.table.clone())
    }
    fn forecast(
        &mut self,
        _: i64,
    ) -> Result<Value, String> {
        Ok(self.forecast.clone())
    }
    fn role_state(
        &mut self,
        _: &str,
    ) -> String {
        self.state.into()
    }
    fn budget_line(&mut self) -> String {
        String::new()
    }
    fn heartbeat(&mut self) -> (Option<i64>, bool) {
        (Some(5), false)
    }
}

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("homund-sched-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn make(
    tag: &str,
    table: Value,
    forecast: Value,
) -> (Scheduler<Fake>, PathBuf) {
    let d = dir(tag);
    let ledger = Ledger {
        dir: d.clone(),
        live: false,
        db: d.join("none"),
    };
    let world = Fake {
        table,
        forecast,
        state: "ok",
    };
    (Scheduler::new(world, ledger, d.join("state.json")), d)
}

fn history(d: &Path) -> Vec<Value> {
    let text = std::fs::read_to_string(d.join("history.jsonl")).unwrap_or_default();
    text.lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

fn forecast(reset: i64) -> Value {
    json!({"five_hour": {"resets_at": reset, "used": 20}, "seven_day": {"resets_at": null,
        "projected_at_reset": 60}, "slots": 2, "burn": {"points": 5, "slots": 2}})
}

#[test]
fn a_due_row_fires_once_and_is_logged() {
    let table = json!([{"name": "tick", "cron": "* * * * *", "prompt": "go"}]);
    let (mut s, d) = make("due", table, forecast(1_000_000));
    s.reload(1000);
    s.run_due(1010);
    assert!(history(&d).is_empty(), "nothing before the next minute");
    s.run_due(1081);
    s.run_due(1082);
    let h = history(&d);
    assert_eq!(h.len(), 1);
    assert_eq!(h[0]["name"], "tick");
    assert_eq!(h[0]["msg"], "[schedule tick] go");
    let events = std::fs::read_to_string(d.join("events")).unwrap();
    assert_eq!(
        events,
        "{\"ts\":1081,\"alarm\":\"tick\",\"msg\":\"[schedule tick] go\"}\n"
    );
}

#[test]
fn a_quiet_role_and_a_disabled_row_stay_silent() {
    let table = json!([
        {"name": "a", "cron": "* * * * *", "prompt": "x", "role": "bot"},
        {"name": "b", "cron": "* * * * *", "prompt": "y", "enabled": false}]);
    let (mut s, d) = make("quiet", table, forecast(1_000_000));
    s.world.state = "quiet";
    s.reload(1000);
    s.run_due(1100);
    assert!(history(&d).is_empty());
}

#[test]
fn catchup_once_replays_one_fire_and_skip_none() {
    let d = dir("catch");
    std::fs::write(d.join("state.json"), r#"{"seen": 1000, "resets": {}}"#).unwrap();
    let table = json!([
        {"name": "once", "cron": "* * * * *", "prompt": "x", "catchup": "once"},
        {"name": "skip", "cron": "* * * * *", "prompt": "y"}]);
    let ledger = Ledger {
        dir: d.clone(),
        live: false,
        db: d.join("none"),
    };
    let mut s = Scheduler::new(
        Fake {
            table,
            forecast: forecast(1_000_000),
            state: "ok",
        },
        ledger,
        d.join("state.json"),
    );
    s.reload(5000);
    s.run_due(5000);
    let names: Vec<_> = history(&d)
        .iter()
        .map(|r| r["name"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(names, ["once"]);
}

#[test]
fn reload_keeps_a_row_whose_cron_did_not_change() {
    let table = json!([{"name": "tick", "cron": "* * * * *", "prompt": "go"}]);
    let (mut s, d) = make("reload", table, forecast(1_000_000));
    s.reload(1000);
    s.run_due(1001);
    s.reload(1050); // same cron: handled stays at 1001, so the 1020 minute is still due
    s.run_due(1081);
    assert_eq!(history(&d).len(), 1);
    s.world.table = json!([{"name": "tick", "cron": "*/5 * * * *", "prompt": "go"}]);
    s.reload(1100); // a changed cron starts now
    s.run_due(1101);
    assert_eq!(history(&d).len(), 1);
}

#[test]
fn forecast_alarms_fire_at_their_time_and_late_ones_are_dropped() {
    let reset = 100_000;
    let (mut s, d) = make("alarms", json!([]), forecast(reset));
    s.reload(reset - 7200);
    s.run_due(reset - 7200); // sees the reset: burn-5h at -3000, window-open at +300
    s.run_due(reset - 3000);
    s.run_due(reset + 300 + 700); // window-open found 700 s late: dropped
    let h = history(&d);
    assert_eq!(h.len(), 1);
    assert_eq!(h[0]["name"], "burn-5h");
    assert!(
        h[0]["msg"]
            .as_str()
            .unwrap()
            .contains("within 5 points and 2 slots")
    );
    let state: Value =
        serde_json::from_str(&std::fs::read_to_string(d.join("state.json")).unwrap()).unwrap();
    assert_eq!(state["resets"][reset.to_string()]["burn-5h"], Value::Null);
}

#[test]
fn the_diff_tells_agreement_from_a_missing_fire() {
    let f = |ts, name: &str| Fire {
        ts,
        name: name.into(),
        msg: "m".into(),
    };
    let (lines, clean) = compare(&[f(100, "a"), f(200, "b")], &[f(130, "a"), f(200, "b")]);
    assert!(clean, "{lines:?}");
    let (lines, clean) = compare(&[f(100, "a")], &[f(100, "b")]);
    assert!(!clean);
    assert_eq!(lines[0], "only-real 100 a");
    assert_eq!(lines[1], "only-shadow 100 b");
}

/// serve.py's ResetAlarms, replayed over the same observations, plans the same alarms.
#[test]
fn reset_alarms_match_serve_py() {
    let serve = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../container/services/scheduler"
    );
    let steps = [
        (100_000, 90_000, "5h"),
        (200_000, 190_000, "7d"),
        (100_200, 99_000, "5h"),
        (300_000, 299_000, "5h"),
        (400_000, 300_000, "7d"),
        (50, 60, "5h"),
    ];
    let script = r#"
import json, sys
sys.path.insert(0, sys.argv[1])
import serve
a = serve.ResetAlarms()
for reset, now, w in json.loads(sys.argv[2]):
    a.observe(reset, now, w)
print(json.dumps(a.to_dict(), sort_keys=True))
"#;
    let Ok(old) = Command::new("python3")
        .args(["-c", script, serve, &json!(steps).to_string()])
        .output()
    else {
        return;
    };
    assert!(
        old.status.success(),
        "{}",
        String::from_utf8_lossy(&old.stderr)
    );
    let mut new = ResetAlarms::default();
    for (reset, now, w) in steps {
        new.observe(
            reset,
            now,
            if w == "7d" {
                Window::SevenDay
            } else {
                Window::FiveHour
            },
        );
    }
    let old: Value = serde_json::from_slice(&old.stdout).unwrap();
    assert_eq!(new.to_json(), old);
}

#[test]
fn messages_and_conditions_match_the_old_ones() {
    let fc = forecast(1);
    assert_eq!(
        message("window-open", &fc).unwrap(),
        "window-open: 2 agent slots available, 40% of the 7d budget projected unused; \
         start queued issue work per your usual rules"
    );
    assert!(allowed("burn-7d", &fc));
    assert!(!allowed(
        "burn-7d",
        &json!({"burn": {"points": 5}, "seven_day": {"projected_at_reset": 97}})
    ));
    assert!(!allowed("window-open", &json!({"slots": 0})));
    assert_eq!(
        message("burn-5h", &json!({})).unwrap().matches('?').count(),
        2
    );
    assert_eq!(message("window-open", &json!({})), None);
}
