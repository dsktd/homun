//! `homund channel serve | shadow [once] | diff | help`: the user and cal channels as one MCP
//! source (M5.2). `serve` is the stdio server (not registered in the plugin yet), `shadow`
//! writes what it would deliver to `channel-shadow/events.jsonl` beside the live scheduler-go,
//! and `diff` compares that log with what the live channels logged. Nothing is dropped: a file
//! or message the source cannot handle is logged as `unhandled` with the reason.

use std::collections::BTreeMap;
use std::collections::BTreeSet;
use std::fs;
use std::io::BufRead;
use std::io::Read;
use std::io::Write;
use std::path::Path;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::mpsc;
use std::time::Duration;
use std::time::SystemTime;

use anyhow::Result;
use serde_json::Value;
use serde_json::json;
use sha2::Digest;
use sha2::Sha256;

const MAX_MESSAGE: usize = 64 * 1024;
const STALL_AFTER: Duration = Duration::from_secs(60);
const STALE_PAUSE: Duration = Duration::from_secs(30 * 60);
const POLL: Duration = Duration::from_millis(500);

const HELP: &str = "homund channel serve | shadow [once] | diff
  serve          the user and cal channels as one MCP stdio server (not registered yet)
  shadow [once]  write the events serve would deliver to bus/<role>/channel-shadow/events.jsonl
  diff           compare that log with the live channels' logs; exit 1 on a difference
  help           this text";

/// One event for the session: the text and the attributes of its `<channel>` tag.
#[derive(Clone, Debug, PartialEq)]
pub struct Event {
    pub content: String,
    pub meta: BTreeMap<String, String>,
}

/// A message as scheduler-go's calEvent reads it: UTF-8, 64 KB, optional `{"meta":..,"text":..}`.
pub fn parse(
    msg: &[u8],
    now: u64,
) -> Result<Event, String> {
    if msg.len() > MAX_MESSAGE {
        return Err("message is larger than 64 KB".into());
    }
    let Ok(text) = std::str::from_utf8(msg) else {
        return Err("message is not valid UTF-8".into());
    };
    let mut text = text.trim().to_owned();
    let mut meta = BTreeMap::from([("ts".to_owned(), now.to_string())]);
    if text.starts_with(r#"{"meta":"#) {
        #[derive(serde::Deserialize)]
        struct Wrapped {
            meta: BTreeMap<String, String>,
            text: String,
        }
        if let Ok(wrapped) = serde_json::from_str::<Wrapped>(&text) {
            text = wrapped.text.trim().to_owned();
            for (k, v) in wrapped.meta {
                let key = (1..=16).contains(&k.len())
                    && k.bytes().all(|b| b.is_ascii_lowercase() || b == b'_');
                if key && k != "ts" && k != "device" && v.len() <= 200 {
                    meta.insert(k, v);
                }
            }
        }
    }
    if text.is_empty() {
        return Err("message is empty".into());
    }
    Ok(Event {
        content: text,
        meta,
    })
}

/// The log entry of a message: size, hash and first line, never all of it.
pub fn audit(msg: &[u8]) -> Value {
    let text = String::from_utf8_lossy(msg);
    let first = text.trim().lines().next().unwrap_or("");
    let first: String = first.chars().take(200).collect();
    let sum: String = Sha256::digest(msg)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    json!({"size": msg.len(), "sha256": sum, "first": first})
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn role() -> String {
    ["CLAUDE_ROLE", "HOMUN_PRIMARY"]
        .iter()
        .find_map(|k| std::env::var(k).ok().filter(|v| !v.is_empty()))
        .unwrap_or("manager".into())
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
}

fn bus_dir() -> PathBuf {
    let root = std::env::var_os("HOMUN_BUS_DIR")
        .map_or_else(|| home().join("claude/.services/bus"), PathBuf::from);
    root.join(role())
}

fn cal_dir() -> PathBuf {
    std::env::var_os("CAL_CHANNEL_DIR")
        .map_or_else(|| home().join("claude/.services/cal"), PathBuf::from)
}

fn digits(name: &str) -> bool {
    name.len() >= 10 && name.bytes().all(|b| b.is_ascii_digit())
}

fn device_ok(name: &str) -> bool {
    let b = name.as_bytes();
    (1..=32).contains(&b.len())
        && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit())
        && b.iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
}

/// A file of the user box, `bus/<role>/user/<device>/<ns>`.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Pending {
    pub name: String,
    pub dev: String,
}

/// The user's box (read-only to the role) and the role's own state beside it.
pub struct UserBox {
    pub dir: PathBuf,
    pub state: PathBuf,
}

impl UserBox {
    pub fn new(bus: &Path) -> UserBox {
        UserBox {
            dir: bus.join("user"),
            state: bus.join("user-state"),
        }
    }

    fn marker(
        &self,
        dev: &str,
        kind: &str,
        id: &str,
    ) -> PathBuf {
        self.state.join(dev).join(kind).join(id)
    }

    pub fn marked(
        &self,
        m: &Pending,
    ) -> bool {
        ["sending", "claimed", "failed"]
            .iter()
            .any(|k| self.marker(&m.dev, k, &m.name).symlink_metadata().is_ok())
    }

    fn paused(
        &self,
        dev: &str,
    ) -> bool {
        let p = self.state.join(dev).join("paused");
        let Ok(age) = fs::metadata(&p)
            .and_then(|m| m.modified())
            .map(|t| t.elapsed().unwrap_or_default())
        else {
            return false;
        };
        if age < STALE_PAUSE {
            return true;
        }
        let _ = fs::remove_file(p);
        false
    }

    /// Every file of the box oldest first, and what could not be read as a message file.
    pub fn scan(&self) -> (Vec<Pending>, Vec<String>) {
        let (mut files, mut odd) = (Vec::new(), Vec::new());
        let mut devs: Vec<_> = fs::read_dir(&self.dir)
            .into_iter()
            .flatten()
            .flatten()
            .collect();
        devs.sort_by_key(|d| d.file_name());
        for d in devs {
            let dev = d.file_name().to_string_lossy().into_owned();
            if !d.path().is_dir() || !device_ok(&dev) {
                odd.push(format!("{dev}: not a device directory"));
                continue;
            }
            for f in fs::read_dir(d.path()).into_iter().flatten().flatten() {
                let name = f.file_name().to_string_lossy().into_owned();
                if f.file_type().is_ok_and(|t| t.is_file()) && digits(&name) {
                    files.push(Pending {
                        name,
                        dev: dev.clone(),
                    });
                } else {
                    odd.push(format!("{dev}/{name}: not a message file"));
                }
            }
        }
        files.sort();
        (files, odd)
    }

    /// The unmarked messages of devices that are not paused, oldest first.
    pub fn waiting(&self) -> Vec<Pending> {
        let mut w: Vec<_> = self
            .scan()
            .0
            .into_iter()
            .filter(|m| !self.marked(m) && !self.paused(&m.dev))
            .collect();
        w.sort_by(|a, b| a.name.cmp(&b.name));
        w
    }

    fn age(
        &self,
        m: &Pending,
    ) -> Option<Duration> {
        let t = fs::metadata(self.dir.join(&m.dev).join(&m.name))
            .ok()?
            .modified()
            .ok()?;
        t.elapsed().ok()
    }

    /// The stall alarm text when the oldest waiting message is over a minute old and is not the
    /// one `last` already alarmed on; `idle` says why it was not taken.
    pub fn stall(
        &self,
        last: &mut String,
        idle: bool,
    ) -> Option<String> {
        let w = self.waiting();
        let Some(m) = w.first() else {
            last.clear();
            return None;
        };
        let age = self.age(m)?;
        if age < STALL_AFTER || *last == m.name {
            return None;
        }
        *last = m.name.clone();
        let why = if idle {
            "the session reads idle but nothing claimed it"
        } else {
            "the session reads busy (busy/status)"
        };
        Some(format!(
            "user message {}/{} unclaimed for {}s: {why}",
            m.dev,
            m.name,
            age.as_secs()
        ))
    }

    /// The event of a pending message, with the entry for its log.
    pub fn read(
        &self,
        m: &Pending,
    ) -> Result<(Event, Value), String> {
        let text = fs::read(self.dir.join(&m.dev).join(&m.name)).map_err(|e| e.to_string())?;
        let mut ev = parse(&text, 0)?;
        ev.meta.insert("ts".into(), m.name[..10].into());
        ev.meta.insert("device".into(), m.dev.clone());
        let mut entry = audit(&text);
        entry["device"] = json!(m.dev);
        entry["id"] = json!(m.name);
        Ok((ev, entry))
    }
}

fn append(
    path: &Path,
    entry: &Value,
) {
    let _ = fs::create_dir_all(path.parent().unwrap_or(Path::new(".")));
    if let Ok(mut f) = fs::OpenOptions::new().append(true).create(true).open(path) {
        let _ = writeln!(f, "{entry}");
    }
}

fn records(path: &Path) -> Vec<Value> {
    fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}

fn shadow_log(bus: &Path) -> PathBuf {
    bus.join("channel-shadow/events.jsonl")
}

/// One shadow pass over the user box and the cal log: log what serve would deliver, what it
/// could not handle, and a stall. Every file and every line ends up in the log once.
pub fn shadow_pass(
    bus: &Path,
    cal: &Path,
) {
    let log = shadow_log(bus);
    let logged = records(&log);
    let key = |r: &Value| {
        (
            r["device"].as_str().unwrap_or("").to_owned(),
            r["id"].as_str().unwrap_or("").to_owned(),
        )
    };
    let seen: BTreeSet<_> = logged
        .iter()
        .filter(|r| r["source"] == "user")
        .map(key)
        .collect();
    let odd_seen: BTreeSet<_> = logged
        .iter()
        .filter_map(|r| r["unhandled"].as_str().map(str::to_owned))
        .collect();
    let ubox = UserBox::new(bus);
    let (files, odd) = ubox.scan();
    for what in odd {
        if !odd_seen.contains(&what) {
            append(&log, &json!({"source": "user", "unhandled": what}));
        }
    }
    for m in files
        .iter()
        .filter(|m| !seen.contains(&(m.dev.clone(), m.name.clone())))
    {
        match ubox.read(m) {
            Ok((_, mut entry)) => {
                entry["source"] = json!("user");
                append(&log, &entry);
            }
            Err(why) => append(
                &log,
                &json!({"source": "user", "device": m.dev, "id": m.name, "unhandled": why}),
            ),
        }
    }
    let stalls: BTreeSet<_> = logged
        .iter()
        .filter_map(|r| r["stall"].as_str().map(str::to_owned))
        .collect();
    let mut last = stalls.iter().next_back().cloned().unwrap_or_default();
    if let Some(msg) = ubox.stall(&mut last, true).filter(|m| !stalls.contains(m)) {
        append(&log, &json!({"source": "user", "stall": msg}));
    }
    // The cal socket belongs to the live listener: the shadow reads its audit log instead.
    let cal_seen = logged.iter().filter(|r| r["source"] == "cal").count();
    for mut r in records(&cal.join("log.jsonl")).into_iter().skip(cal_seen) {
        if let Some(o) = r.as_object_mut() {
            o.remove("time");
            o.insert("source".into(), json!("cal"));
        }
        append(&log, &r);
    }
}

fn pick(r: &Value) -> Value {
    json!([r["size"], r["sha256"], r["first"]])
}

/// The differences between the shadow log and the live logs, one line each.
pub fn diff(
    bus: &Path,
    cal: &Path,
) -> Vec<String> {
    let shadow = records(&shadow_log(bus));
    let live = records(&bus.join("user-state/log.jsonl"));
    let mut out = Vec::new();
    let delivered = |rs: &[Value]| -> BTreeMap<(String, String), Value> {
        rs.iter()
            .filter(|r| r["sha256"].is_string() && r["id"].is_string())
            .map(|r| {
                (
                    (
                        r["device"].as_str().unwrap_or("").into(),
                        r["id"].as_str().unwrap_or("").into(),
                    ),
                    pick(r),
                )
            })
            .collect()
    };
    let (s, l) = (delivered(&shadow), delivered(&live));
    for (k, v) in &l {
        match s.get(k) {
            None => out.push(format!(
                "user {}/{}: live delivered, shadow did not",
                k.0, k.1
            )),
            Some(sv) if sv != v => out.push(format!(
                "user {}/{}: differs: live {v} shadow {sv}",
                k.0, k.1
            )),
            _ => {}
        }
    }
    for k in s.keys().filter(|k| !l.contains_key(*k)) {
        out.push(format!(
            "user {}/{}: shadow only (live has not delivered it)",
            k.0, k.1
        ));
    }
    let hashes = |rs: Vec<Value>, source: bool| -> Vec<Value> {
        rs.into_iter()
            .filter(|r| r["sha256"].is_string() && (!source || r["source"] == "cal"))
            .map(|r| pick(&r))
            .collect()
    };
    let (sc, lc) = (
        hashes(shadow.clone(), true),
        hashes(records(&cal.join("log.jsonl")), false),
    );
    if sc != lc {
        out.push(format!(
            "cal: {} live events, {} in the shadow log",
            lc.len(),
            sc.len()
        ));
    }
    for r in shadow.iter().filter(|r| r["unhandled"].is_string()) {
        out.push(format!(
            "unhandled: {}",
            r["unhandled"].as_str().unwrap_or("")
        ));
    }
    out
}

// ---- the MCP server -------------------------------------------------------------------------

const INSTRUCTIONS: &str = "The user's own messages, written in Markdown, arrive as <channel source=\"user\" device=\"...\" ts=\"...\">text</channel>; device names the screen they typed on (host is the desktop cockpit). They come from the user themselves (only their cockpit can write to this channel) and carry their authority: treat them as their direct instructions in the chat, and answer for that device (shorter on a phone). Messages from the cal channel arrive the same way, without a device. Full syntax of widgets and clicks: the transcript-widgets skill.";

fn send(
    out: &Mutex<std::io::Stdout>,
    v: &Value,
) -> bool {
    let mut o = out.lock().unwrap();
    writeln!(o, "{v}").and_then(|()| o.flush()).is_ok()
}

fn idle(bus: &Path) -> bool {
    let primary = std::env::var("HOMUN_PRIMARY").unwrap_or("manager".into()) == role();
    if !primary {
        return true;
    }
    let status = fs::read(home().join("claude/.services/busy/status")).ok();
    status
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .is_none_or(|s| s["state"] != "busy")
        || !bus.exists()
}

/// Claim, deliver and mark the user box's messages one at a time while the session is idle.
fn user_loop(
    bus: PathBuf,
    events: mpsc::Sender<Event>,
) {
    let ubox = UserBox::new(&bus);
    let log = ubox.state.join("log.jsonl");
    let mut last = String::new();
    loop {
        let ok = idle(&bus);
        if let Some(msg) = ubox.stall(&mut last, ok) {
            append(&log, &json!({"error": msg}));
            let _ = std::process::Command::new("homun-msg")
                .args(["send", &role(), "user-stalled", &msg])
                .status();
        }
        let mut sent = false;
        for m in ubox.waiting().into_iter().filter(|_| ok) {
            let sending = ubox.marker(&m.dev, "sending", &m.name);
            let _ = fs::create_dir_all(sending.parent().unwrap());
            if fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&sending)
                .is_err()
            {
                continue;
            }
            let to = |kind: &str| {
                let p = ubox.marker(&m.dev, kind, &m.name);
                let _ = fs::create_dir_all(p.parent().unwrap());
                let _ = fs::rename(&sending, p);
            };
            match ubox.read(&m) {
                Ok((ev, entry)) if events.send(ev.clone()).is_ok() => {
                    to("claimed");
                    append(&log, &entry);
                }
                other => {
                    let why = other.err().unwrap_or("channel closed".into());
                    to("failed");
                    let _ = fs::write(
                        ubox.state.join(&m.dev).join("paused"),
                        format!("{}\n", m.name),
                    );
                    append(&log, &json!({"device": m.dev, "id": m.name, "error": why}));
                }
            }
            sent = true;
            break;
        }
        if !sent {
            std::thread::sleep(POLL);
        }
    }
}

/// The cal socket, bound once no live holder answers on it.
fn cal_loop(
    dir: PathBuf,
    events: mpsc::Sender<Event>,
) {
    use std::os::unix::net::UnixListener;
    use std::os::unix::net::UnixStream;
    let sock = dir.join("sock");
    loop {
        let _ = fs::create_dir_all(&dir);
        if UnixStream::connect(&sock).is_ok() {
            std::thread::sleep(Duration::from_secs(5));
            continue;
        }
        let _ = fs::remove_file(&sock);
        let Ok(ln) = UnixListener::bind(&sock) else {
            std::thread::sleep(Duration::from_secs(5));
            continue;
        };
        for mut c in ln.incoming().flatten() {
            let _ = c.set_read_timeout(Some(Duration::from_secs(10)));
            let mut msg = Vec::new();
            let _ = (&c).take(MAX_MESSAGE as u64 + 1).read_to_end(&mut msg);
            let reply = match parse(&msg, now()) {
                Ok(ev) => {
                    let mut entry = audit(&msg);
                    entry["time"] = json!(now());
                    append(&dir.join("log.jsonl"), &entry);
                    let _ = events.send(ev);
                    "ok\n".to_owned()
                }
                Err(why) => format!("error: {why}\n"),
            };
            let _ = c.write_all(reply.as_bytes());
        }
    }
}

fn serve() -> Result<()> {
    let out = Arc::new(Mutex::new(std::io::stdout()));
    let (tx, rx) = mpsc::channel::<Event>();
    let (ready_tx, ready_rx) = mpsc::channel::<()>();
    let bus = bus_dir();
    std::thread::spawn({
        let tx = tx.clone();
        move || user_loop(bus, tx)
    });
    if std::env::var("CAL_CHANNEL").is_ok_and(|v| v == "1") {
        let cal = cal_dir();
        std::thread::spawn(move || cal_loop(cal, tx));
    }
    std::thread::spawn({
        let out = out.clone();
        move || {
            if ready_rx.recv().is_err() {
                return;
            }
            for ev in rx {
                let note = json!({"jsonrpc": "2.0", "method": "notifications/claude/channel",
                    "params": {"content": ev.content, "meta": ev.meta}});
                send(&out, &note);
            }
        }
    });
    for line in std::io::stdin().lock().lines() {
        let Ok(Value::Object(m)) = serde_json::from_str::<Value>(&line?) else {
            continue;
        };
        let id = m.get("id").filter(|i| !i.is_null()).cloned();
        let reply = |result: Value| {
            if let Some(id) = &id {
                send(&out, &json!({"jsonrpc": "2.0", "id": id, "result": result}));
            }
        };
        match m.get("method").and_then(Value::as_str).unwrap_or("") {
            "initialize" => {
                let ver = m
                    .get("params")
                    .and_then(|p| p.pointer("/protocolVersion"))
                    .and_then(Value::as_str)
                    .unwrap_or("2025-06-18");
                reply(json!({"protocolVersion": ver,
                    "capabilities": {"experimental": {"claude/channel": {}}},
                    "serverInfo": {"name": "user", "version": "0.1.0"}, "instructions": INSTRUCTIONS}));
            }
            "notifications/initialized" => {
                let _ = ready_tx.send(());
            }
            "ping" => reply(json!({})),
            _ => {
                if let Some(id) = &id {
                    send(
                        &out,
                        &json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "method not found"}}),
                    );
                }
            }
        }
    }
    Ok(())
}

pub fn run(args: &[String]) -> ExitCode {
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    match words[..] {
        ["serve"] => match serve() {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("homund channel: {e}");
                ExitCode::FAILURE
            }
        },
        ["shadow", "once"] => {
            shadow_pass(&bus_dir(), &cal_dir());
            ExitCode::SUCCESS
        }
        ["shadow"] => loop {
            shadow_pass(&bus_dir(), &cal_dir());
            std::thread::sleep(POLL);
        },
        ["diff"] => {
            let lines = diff(&bus_dir(), &cal_dir());
            lines.iter().for_each(|l| println!("{l}"));
            if lines.is_empty() {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            }
        }
        ["help"] => {
            println!("{HELP}");
            ExitCode::SUCCESS
        }
        _ => {
            eprintln!("{HELP}");
            ExitCode::from(2)
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("homund-channel-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn test_parse() {
        let ev = parse(
            br#"{"meta":{"origin":"stage","ts":"1","Bad":"x"},"text":" hi "}"#,
            7,
        )
        .unwrap();
        assert!(ev.content == "hi");
        assert!(ev.meta.len() == 2 && ev.meta["ts"] == "7" && ev.meta["origin"] == "stage");
        assert!(parse(b"  ", 0).unwrap_err() == "message is empty");
        assert!(parse(&[0xff], 0).is_err());
        assert!(parse(&vec![b'a'; MAX_MESSAGE + 1], 0).is_err());
    }

    #[test]
    fn test_shadow_and_diff() {
        let bus = tmp("bus");
        let cal = tmp("cal");
        let dir = bus.join("user/host");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("1700000000111"), "hello\nmore").unwrap();
        fs::write(dir.join("1700000000222"), "  ").unwrap();
        fs::write(dir.join("notes.txt"), "x").unwrap();
        fs::create_dir_all(bus.join("user/Bad Dev")).unwrap();
        fs::write(cal.join("log.jsonl"), format!("{}\n", audit(b"from cal"))).unwrap();
        shadow_pass(&bus, &cal);
        shadow_pass(&bus, &cal);
        let log = records(&shadow_log(&bus));
        let unhandled = log.iter().filter(|r| r["unhandled"].is_string()).count();
        assert!(log.len() == 5 && unhandled == 3, "{log:?}");
        // live delivered the same message: no difference but the unhandled lines
        let mut live = audit(b"hello\nmore");
        live["device"] = json!("host");
        live["id"] = json!("1700000000111");
        append(&bus.join("user-state/log.jsonl"), &live);
        let d = diff(&bus, &cal);
        assert!(
            d.iter().all(|l| l.starts_with("unhandled")) && d.len() == 3,
            "{d:?}"
        );
        live["sha256"] = json!("0");
        append(&bus.join("user-state/log.jsonl"), &live);
        assert!(diff(&bus, &cal).iter().any(|l| l.contains("differs")));
        fs::remove_dir_all(bus).unwrap();
        fs::remove_dir_all(cal).unwrap();
    }

    #[test]
    fn test_stall() {
        let bus = tmp("stall");
        let dir = bus.join("user/host");
        fs::create_dir_all(&dir).unwrap();
        let file = dir.join("1700000000111");
        fs::write(&file, "hi").unwrap();
        let ubox = UserBox::new(&bus);
        let mut last = String::new();
        assert!(ubox.stall(&mut last, true).is_none());
        let old = SystemTime::now() - Duration::from_secs(120);
        fs::File::options()
            .write(true)
            .open(&file)
            .unwrap()
            .set_modified(old)
            .unwrap();
        assert!(ubox.stall(&mut last, false).unwrap().contains("reads busy"));
        assert!(ubox.stall(&mut last, false).is_none());
        fs::remove_dir_all(bus).unwrap();
    }
}
