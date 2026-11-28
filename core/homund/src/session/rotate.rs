//! `homund session rotate`: start a role on a fresh session when its transcript got too big, what
//! container/session-rotate does, with positional keywords:
//!
//!   rotate plan [<session>] [transcript <file>] [threshold <mb>] [turns <n>] [show]
//!   rotate start <session>
//!
//! `start` reads the session's transcript (never writes it): above the threshold (15 MB; the first
//! line of the marker ~/claude/.services/<role>/session-rotate, when a number) it writes a first
//! prompt for a new session to ~/.claude/session-rotate/<new>.prompt, pins the new id in
//! ~/.claude/<role>-session (CLAUDE_ROLE, the manager by default), prints it and exits 0. In
//! every other case it prints nothing on stdout and exits 1, and the old session is resumed. The
//! prompt carries the last compaction summary, the last spoken messages after it and the old
//! transcript's path. `plan` is the dry run.

use std::fs;
use std::path::Path;
use std::path::PathBuf;
use std::process::ExitCode;

use serde_json::Value;

use super::cut;
use super::home;
use super::uuid4;

const THRESHOLD_MB: f64 = 15.0;
const TURNS: usize = 40;
const TURN_CHARS: usize = 2000;
const TAIL_CHARS: usize = 40000;
const PROMPT_BYTES: usize = 110_000; // one argv string holds 128 KiB
const KEY: &[u8] = b"\"isCompactSummary\":true";

/// Why no rotation happens.
pub struct Skip(pub String);

fn skip<T>(why: impl Into<String>) -> Result<T, Skip> {
    Err(Skip(why.into()))
}

pub struct Paths {
    pub state: PathBuf,
    pub marker: PathBuf,
    pub seeds: PathBuf,
    pub pin: PathBuf,
}

impl Paths {
    pub fn from_env() -> Self {
        let state = std::env::var_os("CLAUDE_CONFIG_DIR")
            .map_or_else(|| home().join(".claude"), PathBuf::from);
        let role = std::env::var("CLAUDE_ROLE").ok().filter(|r| !r.is_empty());
        let role = role.unwrap_or("manager".into());
        Self {
            marker: home().join(format!("claude/.services/{role}/session-rotate")),
            seeds: state.join("session-rotate"),
            pin: state.join(format!("{role}-session")),
            state,
        }
    }

    fn threshold_mb(&self) -> f64 {
        let Ok(text) = fs::read_to_string(&self.marker) else {
            return THRESHOLD_MB;
        };
        let first = text.split('\n').next().unwrap_or("").trim();
        if first.is_empty() {
            THRESHOLD_MB
        } else {
            first.parse().unwrap_or(THRESHOLD_MB)
        }
    }

    fn transcript_of(
        &self,
        session: &str,
    ) -> Result<PathBuf, Skip> {
        if !is_uuid(session) {
            return skip(format!("not a session id: '{session}'"));
        }
        let name = format!("{session}.jsonl");
        let found: Vec<PathBuf> = fs::read_dir(self.state.join("projects"))
            .into_iter()
            .flatten()
            .flatten()
            .map(|d| d.path().join(&name))
            .filter(|p| p.is_file())
            .collect();
        if found.len() != 1 {
            return skip(format!("{} transcripts for session {session}", found.len()));
        }
        Ok(found[0].clone())
    }
}

fn is_uuid(s: &str) -> bool {
    let parts: Vec<&str> = s.split('-').collect();
    parts.len() == 5
        && parts.iter().zip([8, 4, 4, 4, 12]).all(|(p, n)| {
            p.len() == n
                && p.bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
}

fn text_of(content: &Value) -> String {
    match content {
        Value::String(s) => s.trim().to_owned(),
        Value::Array(blocks) => blocks
            .iter()
            .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
            .filter_map(|b| b.get("text").and_then(Value::as_str))
            .filter(|t| !t.is_empty())
            .collect::<Vec<_>>()
            .join("\n")
            .trim()
            .to_owned(),
        _ => String::new(),
    }
}

fn content(entry: &Value) -> &Value {
    entry.pointer("/message/content").unwrap_or(&Value::Null)
}

fn rfind(
    data: &[u8],
    needle: &[u8],
    end: usize,
) -> Option<usize> {
    data[..end].windows(needle.len()).rposition(|w| w == needle)
}

/// The last compaction summary and the offset just past its line.
fn last_summary(data: &[u8]) -> Result<(Value, usize), Skip> {
    let mut at = data.len();
    while let Some(found) = rfind(data, KEY, at) {
        at = found;
        let start = data[..at]
            .iter()
            .rposition(|&b| b == b'\n')
            .map_or(0, |i| i + 1);
        let end = data[at..]
            .iter()
            .position(|&b| b == b'\n')
            .map_or(data.len(), |i| at + i);
        let Ok(entry) = serde_json::from_slice::<Value>(&data[start..end]) else {
            continue;
        };
        let real = entry.get("isCompactSummary") == Some(&Value::Bool(true))
            && entry.get("type").and_then(Value::as_str) == Some("user");
        if real && !text_of(content(&entry)).is_empty() {
            return Ok((entry, end + 1));
        }
    }
    skip("no compaction summary in the transcript")
}

fn truthy(v: Option<&Value>) -> bool {
    !matches!(v, None | Some(Value::Null | Value::Bool(false)))
        && v != Some(&Value::from(""))
        && v != Some(&Value::from(0))
}

/// (speaker, text) when the entry is something the user typed or the assistant wrote.
fn spoken(entry: &Value) -> Option<(&'static str, String)> {
    let kind = entry.get("type").and_then(Value::as_str);
    if truthy(entry.get("isSidechain")) || truthy(entry.get("isMeta")) {
        return None;
    }
    let user = match kind {
        Some("user") => true,
        Some("assistant") => false,
        _ => return None,
    };
    if user && entry.get("turnOrigin").and_then(Value::as_str) != Some("human") {
        return None;
    }
    let text = text_of(content(entry));
    if text.is_empty() || (user && (text.starts_with('<') || text.starts_with('['))) {
        return None; // notifications, channel events, commands, interrupts
    }
    Some((if user { "User" } else { "Assistant" }, text))
}

fn stamp(entry: &Value) -> String {
    let raw = match entry.get("timestamp") {
        Some(Value::String(s)) => s.clone(),
        Some(v) => v.to_string(),
        None => String::new(),
    };
    cut(&raw, 16).replace('T', " ")
}

/// The last `turns` spoken messages after the summary, oldest first, within TAIL_CHARS.
fn tail(
    data: &[u8],
    turns: usize,
) -> Vec<String> {
    let mut lines = vec![];
    for raw in data.split(|&b| b == b'\n') {
        let has = |n: &[u8]| raw.windows(n.len()).any(|w| w == n);
        if !has(b"\"type\":\"user\"") && !has(b"\"type\":\"assistant\"") {
            continue;
        }
        let Ok(entry) = serde_json::from_slice::<Value>(raw) else {
            continue;
        };
        if let Some((who, mut text)) = spoken(&entry) {
            if text.chars().count() > TURN_CHARS {
                text = format!("{} [cut]", cut(&text, TURN_CHARS));
            }
            lines.push(format!("[{}Z] {who}: {text}", stamp(&entry)));
        }
    }
    let last = &lines[lines.len().saturating_sub(turns)..];
    let mut kept = vec![];
    let mut used = 0;
    for line in last.iter().rev() {
        let n = line.chars().count();
        if used + n > TAIL_CHARS {
            break;
        }
        kept.push(line.clone());
        used += n;
    }
    kept.reverse();
    kept
}

/// Python's `{:g}` for the thresholds people write.
fn g(v: f64) -> String {
    if v.fract() == 0.0 && v.abs() < 1e16 {
        format!("{v:.0}")
    } else {
        let s = format!("{v:.6}");
        s.trim_end_matches('0').trim_end_matches('.').to_owned()
    }
}

fn seed(
    path: &Path,
    session: &str,
    size: u64,
    limit_mb: f64,
    summary: &Value,
    said: &[String],
) -> String {
    let head = format!(
        "[session rotation] This is a fresh session. The transcript of your previous session \
         {session} had grown to {:.0} MB (limit {} MB), so it was not resumed. It is kept, \
         untouched, at {}: search it (grep, tail; never read it whole) when a detail is missing \
         here. Everything up to the END marker is your own earlier context, not a new request. \
         Not carried over: tool calls and their outputs since the last compaction, background \
         shells, agents and monitors of the old session and their notifications, scheduled \
         wakeups, artifact subscriptions. Check on what you were waiting for (files, the \
         tracker) rather than waiting for a notification.",
        size as f64 / 1e6,
        g(limit_mb),
        path.display()
    );
    let when = match summary.get("timestamp") {
        Some(Value::String(s)) => cut(s, 16).replace('T', " "),
        Some(v) => cut(&v.to_string(), 16).replace('T', " "),
        None => "?".into(),
    };
    [
        head,
        format!("=== Summary written at the last compaction ({when}Z) ==="),
        text_of(content(summary)),
        format!(
            "=== The last {} messages since then, text only, oldest first ===",
            said.len()
        ),
        said.join("\n\n"),
        "=== END of the carried context ===".into(),
    ]
    .join("\n\n")
}

pub struct Plan {
    pub path: PathBuf,
    pub size: u64,
    pub live: u64,
    pub summary: usize,
    pub turns: usize,
    pub tail: usize,
    pub prompt: String,
}

/// Everything `start` needs, from reading the transcript only.
pub fn plan(
    paths: &Paths,
    session: Option<&str>,
    transcript: Option<&Path>,
    limit_mb: f64,
    turns: usize,
) -> Result<Plan, Skip> {
    let path = match transcript {
        Some(t) => t.to_owned(),
        None => paths.transcript_of(session.unwrap_or(""))?,
    };
    let data = fs::read(&path).map_err(|e| Skip(format!("OSError: {e}")))?;
    let size = data.len() as u64;
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    if size as f64 <= limit_mb * 1e6 {
        return skip(format!(
            "{name} is {:.1} MB, not above {} MB",
            size as f64 / 1e6,
            g(limit_mb)
        ));
    }
    let (summary, offset) = last_summary(&data)?;
    let mut said = tail(&data[offset.min(data.len())..], turns);
    let stem = path
        .file_stem()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    let session = session.filter(|s| !s.is_empty()).unwrap_or(&stem);
    let prompt = loop {
        let prompt = seed(&path, session, size, limit_mb, &summary, &said);
        if prompt.len() <= PROMPT_BYTES {
            break prompt;
        }
        if said.is_empty() {
            return skip(format!("the summary alone exceeds {PROMPT_BYTES} bytes"));
        }
        said.remove(0);
    };
    Ok(Plan {
        live: size.saturating_sub(offset as u64),
        summary: text_of(content(&summary)).chars().count(),
        turns: said.len(),
        tail: said.iter().map(|s| s.chars().count()).sum(),
        path,
        size,
        prompt,
    })
}

/// Atomically, private.
fn write_private(
    path: &Path,
    text: &str,
) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let name = format!(
        "{}.tmp.{}",
        path.file_name().unwrap_or_default().to_string_lossy(),
        std::process::id()
    );
    let tmp = path.with_file_name(name);
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?;
    f.write_all(text.as_bytes())?;
    fs::rename(tmp, path)
}

fn start(
    paths: &Paths,
    session: &str,
) -> Result<String, Skip> {
    let done = plan(paths, Some(session), None, paths.threshold_mb(), TURNS)?;
    let new = uuid4();
    let io = |e: std::io::Error| Skip(format!("OSError: {e}"));
    {
        use std::os::unix::fs::DirBuilderExt;
        let made = fs::DirBuilder::new().mode(0o700).create(&paths.seeds);
        if let Err(e) = made
            && e.kind() != std::io::ErrorKind::AlreadyExists
        {
            return Err(io(e));
        }
    }
    write_private(&paths.seeds.join(format!("{new}.prompt")), &done.prompt).map_err(io)?;
    write_private(&paths.pin, &format!("{new}\n")).map_err(io)?;
    Ok(new)
}

pub fn main(args: &[String]) -> ExitCode {
    let paths = Paths::from_env();
    let no = |why: String| {
        eprintln!("homund session rotate: no rotation: {why}");
        ExitCode::FAILURE
    };
    match args.first().map(String::as_str) {
        Some("start") => match args.get(1) {
            Some(session) => match start(&paths, session) {
                Ok(new) => {
                    println!("{new}");
                    ExitCode::SUCCESS
                }
                Err(Skip(why)) => no(why),
            },
            None => no("start needs a session id".into()),
        },
        Some("plan") => {
            let mut session = None;
            let mut transcript = None;
            let mut limit = None;
            let mut turns = TURNS;
            let mut show = false;
            let mut words = args[1..].iter();
            while let Some(w) = words.next() {
                match w.as_str() {
                    "transcript" => transcript = words.next().map(PathBuf::from),
                    "threshold" => limit = words.next().and_then(|v| v.parse().ok()),
                    "turns" => turns = words.next().and_then(|v| v.parse().ok()).unwrap_or(TURNS),
                    "show" => show = true,
                    s if session.is_none() => session = Some(s.to_owned()),
                    s => return no(format!("unknown word {s}")),
                }
            }
            if session.is_none() && transcript.is_none() {
                session = fs::read_to_string(&paths.pin)
                    .ok()
                    .map(|s| s.trim().to_owned());
            }
            let limit = limit.unwrap_or_else(|| paths.threshold_mb());
            match plan(
                &paths,
                session.as_deref(),
                transcript.as_deref(),
                limit,
                turns,
            ) {
                Ok(done) => {
                    print_plan(&paths, &done, limit, show);
                    ExitCode::SUCCESS
                }
                Err(Skip(why)) => no(why),
            }
        }
        _ => {
            eprintln!("{}", super::HELP);
            ExitCode::from(2)
        }
    }
}

fn print_plan(
    paths: &Paths,
    done: &Plan,
    limit: f64,
    show: bool,
) {
    let state = if paths.marker.exists() {
        "on".to_owned()
    } else {
        format!("off (enable: touch {})", paths.marker.display())
    };
    println!("rotation:      {state}");
    println!("transcript:    {}", done.path.display());
    println!(
        "size:          {:.1} MB (limit {} MB)",
        done.size as f64 / 1e6,
        g(limit)
    );
    println!(
        "live part:     {:.1} MB after the last compaction summary",
        done.live as f64 / 1e6
    );
    println!("summary:       {} characters", done.summary);
    println!(
        "carried turns: {} messages, {} characters",
        done.turns, done.tail
    );
    let size = done.prompt.len();
    println!(
        "new prompt:    {size} bytes, about {} tokens (cap {PROMPT_BYTES} bytes)",
        size / 4
    );
    println!("would: write the prompt, pin a new session id, start claude --session-id <new>");
    if show {
        println!("{}", "-".repeat(72));
        println!("{}", done.prompt);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn g_formats_like_python() {
        assert_eq!(g(15.0), "15");
        assert_eq!(g(0.5), "0.5");
        assert_eq!(g(0.001), "0.001");
    }

    #[test]
    fn uuid_shape() {
        assert!(is_uuid(&uuid4()));
        assert!(!is_uuid("../x"));
    }
}
