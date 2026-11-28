//! The scheduler as a running service (what `Scheduler`, `Table`, `Ledger` and `main` of
//! container/services/scheduler/serve.py do): reload the table, fire what is due, keep the
//! forecast alarms, record each fire in a ledger. The org files and the HTTP page stay in serve.py.
//!
//! `homund sched run shadow` writes only its own ledger (events and history.jsonl in the shadow
//! directory) and sends nothing; `run live` is the same loop with the bus and the usage database.

use std::collections::HashMap;
use std::io::Read;
use std::io::Write;
use std::net::TcpStream;
use std::path::Path;
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;
use std::time::SystemTime;

use serde_json::Value;
use serde_json::json;

use crate::alarms;
use crate::alarms::ResetAlarms;
use crate::alarms::Window;
use crate::sched::Cron;

const STALE: i64 = 180; // a listener heartbeat older than this is stale
const TICK: i64 = 5; // longest sleep: the table file and the forecast are looked at this often
const SAVE_EVERY: i64 = 60; // a pass saves the state at least this often, and whenever it changed

fn log(text: &str) {
    println!("scheduler: {text}");
}

pub struct Entry {
    pub name: String,
    pub expr: String,
    pub cron: Cron,
    pub prompt: String,
    pub target: String,
    pub model: String,
    pub budget: Option<i64>,
    pub role: Option<String>,
    pub catchup: String,
    pub enabled: bool,
}

impl Entry {
    fn parse(row: &Value) -> Result<Self, String> {
        let text = |k: &str| row.get(k).and_then(Value::as_str).map(str::to_owned);
        let (Some(name), Some(expr), Some(prompt)) = (text("name"), text("cron"), text("prompt"))
        else {
            return Err("name, cron and prompt are text".into());
        };
        let budget = match row.get("budget") {
            None | Some(Value::Null) => None,
            Some(b) => Some(b.as_i64().ok_or("budget is a number")?),
        };
        let or = |k: &str, d: &str| text(k).filter(|t| !t.is_empty()).unwrap_or(d.into());
        Ok(Self {
            cron: Cron::parse(&expr)?,
            name,
            expr,
            prompt,
            target: or("target", "auto"),
            model: or("model", "haiku"),
            budget,
            role: text("role"),
            catchup: or("catchup", "skip"),
            enabled: row.get("enabled") != Some(&Value::Bool(false)),
        })
    }

    pub fn message(&self) -> String {
        let head = format!("[schedule {}] ", self.name);
        if self.target == "headless" {
            return format!(
                "{head}(headless: start a background session, model {}, with this prompt) {}",
                self.model, self.prompt
            );
        }
        head + &self.prompt
    }
}

/// The valid rows of a table (a bad row is skipped with a log line).
pub fn entries(rows: &Value) -> Vec<Entry> {
    let mut found = Vec::new();
    for row in rows.as_array().into_iter().flatten() {
        match Entry::parse(row) {
            Ok(entry) => found.push(entry),
            Err(err) => log(&format!("skipping a table row: {err}")),
        }
    }
    found
}

/// Everything the scheduler reads from outside, so a test can stand in for it.
pub trait World {
    /// The table rows; Err when the file cannot be read (the old table stays).
    fn table(&mut self) -> Result<Value, String>;
    /// The forecast no older than `max_age` seconds (0: fetch now).
    fn forecast(
        &mut self,
        max_age: i64,
    ) -> Result<Value, String>;
    /// The role's spend state (ok, quiet, over, n/a); ok when it cannot be read.
    fn role_state(
        &mut self,
        role: &str,
    ) -> String;
    /// claude-usage's one budgets line; empty when it cannot run.
    fn budget_line(&mut self) -> String;
    /// Seconds since the listener's last touch (None without a file), and whether that is stale.
    fn heartbeat(&mut self) -> (Option<i64>, bool);
}

/// Where a fire is written: the events file and the history always; the bus and the usage
/// database only when `live`.
pub struct Ledger {
    pub dir: PathBuf,
    pub live: bool,
    pub db: PathBuf,
}

impl Ledger {
    fn append(
        &self,
        file: &str,
        value: &Value,
    ) -> std::io::Result<()> {
        let line = format!("{value}\n");
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.dir.join(file))?;
        f.write_all(line.as_bytes()) // one write, O_APPEND
    }

    pub fn record(
        &self,
        ts: i64,
        alarm: &str,
        msg: &str,
        (missed, age, manual): (bool, Option<i64>, bool),
    ) -> std::io::Result<()> {
        self.append("events", &json!({"ts": ts, "alarm": alarm, "msg": msg}))?;
        if self.live {
            self.bus(alarm, msg);
        }
        let rec = json!({"ts": ts, "name": alarm, "msg": msg, "missed": missed,
            "listener_age_s": age, "manual": manual});
        if let Err(err) = self.append("history.jsonl", &rec) {
            // the events line is out: a lost record must not stop the pass
            log(&format!("history record not written: {err}"));
        }
        if self.live {
            self.row(ts, if missed { "missed" } else { "fire" }, alarm);
        }
        Ok(())
    }

    fn bus(
        &self,
        alarm: &str,
        msg: &str,
    ) {
        let sent = std::env::current_exe().and_then(|me| {
            Command::new(me)
                .args(["msg", "send", "manager", alarm, msg])
                .output()
        });
        if !sent.is_ok_and(|o| o.status.success()) {
            log(&format!("bus send {alarm} failed"));
        }
    }

    /// The `events` row in usage.sqlite is a bonus on top of the two files: its failure is logged.
    fn row(
        &self,
        ts: i64,
        kind: &str,
        detail: &str,
    ) {
        if !self.db.exists() {
            return log(&format!(
                "no usage db at {}, no events row",
                self.db.display()
            ));
        }
        let q = |s: &str| format!("'{}'", s.replace('\'', "''"));
        let sql = format!(
            "create table if not exists events (ts integer not null, source text, kind text, \
             detail text, session_id text); insert into events (ts, source, kind, detail, \
             session_id) values ({ts}, 'scheduler', {}, {}, null)",
            q(kind),
            q(detail)
        );
        let done = Command::new("sqlite3").arg(&self.db).arg(sql).output();
        if !done.is_ok_and(|o| o.status.success()) {
            log("events row not written");
        }
    }
}

struct Slot {
    entry: Entry,
    handled: i64, // the time up to which this entry's fires were dealt with
}

pub struct Scheduler<W: World> {
    pub world: W,
    pub ledger: Ledger,
    state_path: PathBuf,
    seen: Option<i64>, // the time the service was last running
    resets: ResetAlarms,
    slots: Vec<Slot>,
    first_load: bool,
    last_save: i64,
    saved: String, // the state as last written, without `seen`
}

impl<W: World> Scheduler<W> {
    pub fn new(
        world: W,
        ledger: Ledger,
        state_path: PathBuf,
    ) -> Self {
        let saved: Value = std::fs::read_to_string(&state_path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        Self {
            world,
            ledger,
            seen: saved.get("seen").and_then(Value::as_i64),
            resets: ResetAlarms::from_json(saved.get("resets")),
            state_path,
            slots: Vec::new(),
            first_load: true,
            last_save: 0,
            saved: String::new(),
        }
    }

    /// Re-read the table. Enabled entries with an unchanged cron keep their handled time; new,
    /// changed and just re-enabled ones start now (no replay of what a disabled entry missed), or,
    /// with catchup `once` at the first load, at the time the service was last seen.
    pub fn reload(
        &mut self,
        now: i64,
    ) -> bool {
        let fresh = match self.world.table() {
            Ok(rows) => entries(&rows),
            Err(err) => {
                log(&format!("table not read, keeping the old one: {err}"));
                return false;
            }
        };
        let mut old: HashMap<String, Slot> = std::mem::take(&mut self.slots)
            .into_iter()
            .map(|s| (s.entry.name.clone(), s))
            .collect();
        let count = fresh.len();
        for entry in fresh {
            let kept = old.remove(&entry.name);
            let handled = match (kept, self.seen) {
                (Some(k), _) if k.entry.expr == entry.expr && k.entry.enabled => k.handled,
                (_, Some(seen)) if self.first_load && entry.catchup == "once" => seen.min(now),
                (_, seen) => {
                    let missed = seen
                        .filter(|_| self.first_load && entry.enabled)
                        .and_then(|s| entry.cron.next_after(s))
                        .filter(|m| *m <= now);
                    if missed.is_some() {
                        log(&format!(
                            "schedule {} skipped: service was down at its fire time, catchup skip",
                            entry.name
                        ));
                    }
                    now
                }
            };
            self.slots.push(Slot { entry, handled });
        }
        self.first_load = false;
        log(&format!("table loaded: {count} schedules"));
        true
    }

    fn observe_forecast(
        &mut self,
        now: i64,
    ) {
        if let Ok(fc) = self.world.forecast(300) {
            for (window, key) in [
                (Window::FiveHour, "five_hour"),
                (Window::SevenDay, "seven_day"),
            ] {
                // null before the first usage sample
                if let Some(reset) = fc[key]["resets_at"].as_f64() {
                    self.resets.observe(reset as i64, now, window);
                }
            }
        }
    }

    fn deliver(
        &mut self,
        now: i64,
        name: &str,
        msg: &str,
        manual: bool,
    ) {
        let (age, missed) = self.world.heartbeat();
        if let Err(err) = self.ledger.record(now, name, msg, (missed, age, manual)) {
            return log(&format!("fire failed: {err}"));
        }
        let (flag, how) = (
            if missed { "MISSED " } else { "" },
            if manual { " (manual)" } else { "" },
        );
        log(&format!("{flag}fired {name}{how}: {msg}"));
    }

    fn within_budget(
        &mut self,
        budget: Option<i64>,
    ) -> bool {
        let Some(budget) = budget else {
            return true;
        };
        let used = self
            .world
            .forecast(60)
            .ok()
            .and_then(|fc| fc["five_hour"]["used"].as_f64());
        used.is_none_or(|used| 100.0 - used >= budget as f64)
    }

    /// The message of a due forecast alarm; None when it must not be sent.
    fn due_message(
        &mut self,
        name: &str,
    ) -> Option<String> {
        let fc = self.world.forecast(0).unwrap_or_else(|_| json!({}));
        if !alarms::allowed(name, &fc) {
            return None;
        }
        let mut msg = alarms::message(name, &fc)?;
        if name != "burn-7d" {
            let line = self.world.budget_line();
            if !line.is_empty() {
                msg += &format!("; {line}");
            }
        }
        Some(msg)
    }

    /// Fire everything due at `now`, however late (a table entry once, whatever it missed).
    pub fn run_due(
        &mut self,
        now: i64,
    ) {
        self.observe_forecast(now);
        for i in 0..self.slots.len() {
            let slot = &self.slots[i];
            let due = slot.entry.enabled
                && slot
                    .entry
                    .cron
                    .next_after(slot.handled)
                    .is_some_and(|n| n <= now);
            if !due {
                continue;
            }
            self.slots[i].handled = now;
            let (name, role, budget, msg) = {
                let e = &self.slots[i].entry;
                (e.name.clone(), e.role.clone(), e.budget, e.message())
            };
            let state = role
                .as_deref()
                .map_or("ok".into(), |r| self.world.role_state(r));
            if state == "quiet" || state == "over" {
                let role = role.unwrap_or_default();
                log(&format!(
                    "schedule {name} skipped: role {role} is {state} on its daily budget"
                ));
            } else if self.within_budget(budget) {
                self.deliver(now, &name, &msg, false);
            } else {
                log(&format!(
                    "schedule {name} skipped: over its budget limit {}",
                    budget.unwrap_or(0)
                ));
            }
        }
        for (name, at, reset) in self.resets.pending() {
            if at > now {
                break;
            }
            self.resets.finish(&name, reset);
            let msg = if now - at > alarms::LATE {
                None
            } else {
                self.due_message(&name)
            };
            match msg {
                Some(msg) => self.deliver(now, &name, &msg, false),
                None => log(&format!("{name} for reset {reset} not sent")),
            }
        }
        self.save(now);
    }

    fn save(
        &mut self,
        now: i64,
    ) {
        self.seen = Some(now);
        let resets = self.resets.to_json().to_string();
        if resets == self.saved && now - self.last_save < SAVE_EVERY {
            return;
        }
        let state = json!({"seen": now, "resets": self.resets.to_json()});
        self.saved = resets;
        let tmp = self.state_path.with_extension("tmp");
        let saved = std::fs::write(&tmp, state.to_string())
            .and_then(|()| std::fs::rename(&tmp, &self.state_path));
        if let Err(err) = saved {
            log(&format!("state not saved: {err}"));
        }
        self.last_save = now;
    }

    /// Seconds until the nearest fire, at most TICK.
    pub fn sleep_seconds(
        &self,
        now: i64,
    ) -> i64 {
        let table = self
            .slots
            .iter()
            .filter(|s| s.entry.enabled)
            .filter_map(|s| s.entry.cron.next_after(s.handled));
        let resets = self.resets.pending().into_iter().map(|(_, at, _)| at);
        table
            .chain(resets)
            .min()
            .map_or(TICK, |t| (t - now).clamp(0, TICK))
    }
}

/// The real world: nu for the table and the budgets, a socket for the forecast, a file's mtime.
pub struct Host {
    pub table: PathBuf,
    pub forecast_url: String,
    pub heartbeat: PathBuf,
    cached: Option<(Value, i64)>,
}

fn epoch() -> i64 {
    chrono::Utc::now().timestamp()
}

fn usage(args: &[&str]) -> Option<String> {
    let script = std::env::var("CLAUDE_USAGE").unwrap_or_else(|_| {
        format!(
            "{}/claude/_tools/homun/bin/claude-usage",
            std::env::var("HOME").unwrap_or_default()
        )
    });
    let out = Command::new("nu")
        .arg(script)
        .args(["db", "budgets"])
        .args(args)
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

/// A body fetched with a bare HTTP/1.0 GET from 127.0.0.1, or the file of a file:// URL.
fn fetch(url: &str) -> Result<String, String> {
    if let Some(path) = url.strip_prefix("file://") {
        return std::fs::read_to_string(path).map_err(|e| e.to_string());
    }
    let rest = url
        .strip_prefix("http://")
        .ok_or("only http:// and file:// urls")?;
    let (host, path) = rest.split_once('/').map_or((rest, ""), |(h, p)| (h, p));
    let timeout = Some(Duration::from_secs(3));
    let addr = host
        .parse()
        .map_err(|_| "the host must be an ip:port".to_owned())?;
    let mut s =
        TcpStream::connect_timeout(&addr, Duration::from_secs(3)).map_err(|e| e.to_string())?;
    s.set_read_timeout(timeout).map_err(|e| e.to_string())?;
    write!(s, "GET /{path} HTTP/1.0\r\nHost: {host}\r\n\r\n").map_err(|e| e.to_string())?;
    let mut reply = String::new();
    s.read_to_string(&mut reply).map_err(|e| e.to_string())?;
    let (head, body) = reply.split_once("\r\n\r\n").ok_or("no http reply")?;
    if !head.starts_with("HTTP/1.0 200") && !head.starts_with("HTTP/1.1 200") {
        return Err(head.lines().next().unwrap_or("").to_owned());
    }
    Ok(body.to_owned())
}

impl World for Host {
    fn table(&mut self) -> Result<Value, String> {
        if !self.table.exists() {
            return Ok(json!([]));
        }
        let out = Command::new("nu")
            .args(["-c", "open $env.SCHEDULER_TABLE | to json"])
            .env("SCHEDULER_TABLE", &self.table)
            .output()
            .map_err(|e| e.to_string())?;
        if !out.status.success() {
            return Err(String::from_utf8_lossy(&out.stderr)
                .chars()
                .take(200)
                .collect());
        }
        let text = String::from_utf8_lossy(&out.stdout);
        let rows: Value = serde_json::from_str(if text.trim().is_empty() { "[]" } else { &text })
            .map_err(|e| e.to_string())?;
        Ok(if rows.is_null() { json!([]) } else { rows })
    }

    fn forecast(
        &mut self,
        max_age: i64,
    ) -> Result<Value, String> {
        if let Some((fc, at)) = &self.cached
            && epoch() - at < max_age
        {
            return Ok(fc.clone());
        }
        let fc: Value =
            serde_json::from_str(&fetch(&self.forecast_url)?).map_err(|e| e.to_string())?;
        fc["five_hour"]
            .get("resets_at")
            .ok_or("no five_hour.resets_at")?;
        self.cached = Some((fc.clone(), epoch()));
        Ok(fc)
    }

    fn role_state(
        &mut self,
        role: &str,
    ) -> String {
        let rows: Value = usage(&["json"])
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        rows.as_array()
            .into_iter()
            .flatten()
            .find(|r| r["role"] == role)
            .and_then(|r| r["state"].as_str())
            .unwrap_or("ok")
            .to_owned()
    }

    fn budget_line(&mut self) -> String {
        usage(&["alert"]).unwrap_or_default()
    }

    fn heartbeat(&mut self) -> (Option<i64>, bool) {
        let age = std::fs::metadata(&self.heartbeat)
            .and_then(|m| m.modified())
            .ok()
            .map(|t| {
                SystemTime::now()
                    .duration_since(t)
                    .map_or(0, |d| d.as_secs() as i64)
            });
        (age, age.is_none_or(|a| a > STALE))
    }
}

fn env_path(
    key: &str,
    fallback: impl FnOnce() -> PathBuf,
) -> PathBuf {
    std::env::var_os(key)
        .filter(|v| !v.is_empty())
        .map_or_else(fallback, PathBuf::from)
}

/// The service loop; never returns. `live` false is the shadow: its own directory, nothing sent.
pub fn serve(live: bool) -> Result<(), String> {
    let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
    let services = env_path("CLAUDE_SERVICES_DIR", || home.join("claude/.services"));
    let real = env_path("SCHEDULER_DIR", || services.join("scheduler"));
    let dir = if live {
        real
    } else {
        env_path("SCHEDULER_SHADOW_DIR", || services.join("scheduler-shadow"))
    };
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let since = dir.join("since"); // when the shadow first ran: `sched diff` compares from here
    if !live && !since.exists() {
        std::fs::write(&since, epoch().to_string()).map_err(|e| e.to_string())?;
    }
    let sched_dir = env_path("CLAUDE_SCHED_DIR", || services.join("sched"));
    let host = Host {
        table: env_path("SCHEDULER_TABLE", || sched_dir.join("schedules.nuon")),
        forecast_url: std::env::var("SCHEDULER_FORECAST_URL")
            .unwrap_or_else(|_| "http://127.0.0.1:8420/forecast.json".into()),
        heartbeat: env_path("SCHEDULER_HEARTBEAT", || {
            "/dev/shm/claude-scheduler/listener".into()
        }),
        cached: None,
    };
    let ledger = Ledger {
        dir: dir.clone(),
        live,
        db: env_path("SCHEDULER_DB", || services.join("usage-db/usage.sqlite")),
    };
    let mut sched = Scheduler::new(host, ledger, dir.join("state.json"));
    log(&format!(
        "{} mode, state in {}",
        if live { "live" } else { "shadow" },
        dir.display()
    ));
    let mtime = |p: &Path| std::fs::metadata(p).and_then(|m| m.modified()).ok();
    let table = sched.world.table.clone();
    let mut loaded = None;
    loop {
        let now = epoch();
        let stamp = mtime(&table);
        if loaded != Some(stamp) && sched.reload(now) {
            loaded = Some(stamp);
        }
        sched.run_due(now);
        std::thread::sleep(Duration::from_secs(
            sched.sleep_seconds(epoch()).max(1) as u64
        ));
    }
}
