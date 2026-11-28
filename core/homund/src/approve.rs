//! `homund approve`: the PermissionRequest hook (what `container/permission-hook.sh` did). Reads
//! the hook input on stdin, writes `approve/requests/<id>.json` {id, tool, summary, input, agent,
//! since, timeout} (temp + rename), waits up to `APPROVE_TIMEOUT` seconds (default 60) for
//! `approve/answers/<id>` holding `allow`, `deny` or {"behavior":"deny","message":REASON}, and
//! prints the decision. The record also carries `cwd`, its worktree `root`, the asking agent's
//! `agent_name` and the `risk` class (`crate::risk`). Quiet mode (the marker `answers/quiet`,
//! which only the cockpit can write) allows a `read-only` request at once, with no request file,
//! and journals it `via "auto"`. No answer in time, or anything else wrong: no output and exit 0, so the
//! terminal prompt appears. Only the Manager's own session answers (`HOMUN_IS_ROLE` script,
//! default /opt/homun/is-role.sh, with `primary`); a headless one is answered by its broker.
//! The request file is removed on every exit but SIGKILL; SIGTERM, SIGINT and SIGHUP end the wait
//! with exit 0, as the legacy shell trap did.

use std::fs;
use std::io::Read;
use std::path::Path;
use std::path::PathBuf;
use std::process::Command;
use std::process::ExitCode;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use std::time::Duration;
use std::time::SystemTime;
use std::time::UNIX_EPOCH;

use serde_json::Value;
use serde_json::json;

const DOC: &str = "homund approve   (PermissionRequest hook: hook input on stdin, decision on stdout)\n\
APPROVE_DIR, APPROVE_TIMEOUT, HOMUN_IS_ROLE and HOMUN_HEADLESS are read from the environment.\n";

fn cut(
    text: &str,
    n: usize,
) -> String {
    text.chars().take(n).collect()
}

/// The request record for the hook input `hook`, or None when it cannot be shown.
pub fn request(
    hook: &Value,
    id: &str,
    since: u64,
    timeout: u64,
) -> Option<Value> {
    let input = match &hook["tool_input"] {
        Value::Null => json!({}),
        v @ Value::Object(_) => v.clone(),
        _ => return None,
    };
    let text = |v: &Value| match v {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    };
    let summary = ["command", "file_path", "url", "pattern"]
        .iter()
        .map(|k| &input[*k])
        .find(|v| !v.is_null() && **v != Value::Bool(false))
        .map_or_else(|| input.to_string(), text);
    let cutdown: Value = input
        .as_object()?
        .iter()
        .map(|(k, v)| {
            let v = v
                .as_str()
                .map_or_else(|| v.clone(), |s| Value::String(cut(s, 4000)));
            (k.clone(), v)
        })
        .collect::<serde_json::Map<_, _>>()
        .into();
    let input = if cutdown.to_string().chars().count() > 6000 {
        json!({})
    } else {
        cutdown
    };
    let cwd = PathBuf::from(hook["cwd"].as_str().unwrap_or("/"));
    let root = crate::risk::worktree_root(&cwd);
    let tool = hook["tool_name"].as_str().unwrap_or("?");
    let risk = crate::risk::classify(tool, &hook["tool_input"], &cwd, &root);
    let agent_type = hook["agent_type"].as_str().filter(|t| !t.is_empty());
    let agent = hook["agent_id"]
        .as_str()
        .filter(|a| !a.is_empty())
        .map(|a| json!({"id": a, "type": hook["agent_type"].as_str().unwrap_or("")}));
    Some(json!({
        "id": id,
        "tool": tool,
        "summary": cut(&summary, 400),
        "input": input,
        "agent": agent,
        "since": since,
        "timeout": timeout,
        "cwd": cwd,
        "root": root,
        "agent_name": agent_type.unwrap_or("main"),
        "risk": risk.name(),
    }))
}

/// The hook's stdout for an answer file's text, or None while it says nothing usable.
pub fn decision(answer: &str) -> Option<Value> {
    let out = |d: Value| json!({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": d}});
    match answer {
        "allow" => Some(out(json!({"behavior": "allow"}))),
        "deny" => Some(out(
            json!({"behavior": "deny", "message": "The user denied this in Emacs"}),
        )),
        _ if answer.starts_with("{\"behavior\":\"deny\"") => {
            let row: Value = serde_json::from_str(answer).ok()?;
            let why = match &row["message"] {
                Value::Null => String::new(),
                Value::String(s) => s.clone(),
                other => other.to_string(),
            };
            Some(out(
                json!({"behavior": "deny", "message": format!("The user denied this: {}", cut(&why, 1000))}),
            ))
        }
        _ => None,
    }
}

/// Journals the quiet-mode allow of `record`, for the cockpit's ticker.
fn auto_allow(
    dir: &Path,
    record: &Value,
) {
    let line = json!({
        "time": chrono::Utc::now().format("%FT%TZ").to_string(),
        "id": record["id"], "answer": "allow", "via": "auto",
        "tool": record["tool"], "summary": cut(record["summary"].as_str().unwrap_or(""), 120),
        "agent": record["agent_name"],
    });
    let _ = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("journal.jsonl"))
        .and_then(|mut f| std::io::Write::write_all(&mut f, format!("{line}\n").as_bytes()));
}

static STOP: AtomicBool = AtomicBool::new(false);

unsafe extern "C" {
    fn signal(
        signum: i32,
        handler: extern "C" fn(i32),
    ) -> usize;
}

extern "C" fn on_signal(_: i32) {
    STOP.store(true, Ordering::Relaxed);
}

/// Makes SIGHUP, SIGINT and SIGTERM set `STOP` instead of killing the process.
fn catch_signals() {
    for sig in [1, 2, 15] {
        // SAFETY: the handler only stores to an atomic, which is async-signal-safe.
        unsafe { signal(sig, on_signal) };
    }
}

struct Pending(PathBuf);

impl Drop for Pending {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

fn read_answer(path: &Path) -> Option<String> {
    let mut buf = vec![];
    fs::File::open(path)
        .ok()?
        .take(4000)
        .read_to_end(&mut buf)
        .ok()?;
    Some(String::from_utf8_lossy(&buf).into_owned())
}

pub fn run(args: &[String]) -> ExitCode {
    if args.first().is_some_and(|a| a == "help" || a == "--help") {
        print!("{DOC}");
        return ExitCode::SUCCESS;
    }
    let mut raw = String::new();
    let _ = std::io::stdin().read_to_string(&mut raw);
    let role = std::env::var("HOMUN_IS_ROLE").unwrap_or("/opt/homun/is-role.sh".into());
    if !Command::new("sh")
        .args([&role, "primary"])
        .status()
        .is_ok_and(|s| s.success())
        || std::env::var_os("HOMUN_HEADLESS").is_some_and(|v| !v.is_empty())
    {
        return ExitCode::SUCCESS;
    }
    let dir = std::env::var_os("APPROVE_DIR")
        .filter(|v| !v.is_empty())
        .map_or_else(
            || {
                PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                    .join("claude/.services/approve")
            },
            PathBuf::from,
        );
    let timeout: u64 = std::env::var("APPROVE_TIMEOUT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(60);
    let (requests, answers) = (dir.join("requests"), dir.join("answers"));
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let id = format!("{}-{}", now.as_nanos(), std::process::id());
    let Some(record) = serde_json::from_str::<Value>(&raw)
        .ok()
        .and_then(|hook| request(&hook, &id, now.as_secs(), timeout))
    else {
        return ExitCode::SUCCESS;
    };
    if record["risk"] == "read-only" && answers.join("quiet").exists() {
        auto_allow(&dir, &record);
        println!("{}", decision("allow").unwrap_or_default());
        return ExitCode::SUCCESS;
    }
    let (req, tmp) = (
        requests.join(format!("{id}.json")),
        requests.join(format!("{id}.json.tmp")),
    );
    if fs::create_dir_all(&requests)
        .and_then(|()| fs::create_dir_all(&answers))
        .and_then(|()| fs::write(&tmp, record.to_string()))
        .and_then(|()| fs::rename(&tmp, &req))
        .is_err()
    {
        let _ = fs::remove_file(&tmp);
        return ExitCode::SUCCESS;
    }
    let _pending = Pending(req);
    catch_signals();
    for _ in 0..timeout * 2 {
        if STOP.load(Ordering::Relaxed) {
            break;
        }
        if let Some(out) = read_answer(&answers.join(&id)).and_then(|a| decision(&a)) {
            println!("{out}");
            break;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    ExitCode::SUCCESS
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_request_summary_and_agent() {
        let hook = json!({"tool_name": "Bash", "tool_input": {"command": "ls", "x": "y"},
                          "agent_id": "a1", "agent_type": "Explore"});
        let r = request(&hook, "1-2", 5, 60).unwrap();
        assert_eq!(r["summary"], "ls");
        assert_eq!(r["agent"], json!({"id": "a1", "type": "Explore"}));
        let r = request(&json!({"tool_input": {"n": 1}}), "i", 0, 60).unwrap();
        assert_eq!(r["tool"], "?");
        assert_eq!(r["summary"], "{\"n\":1}");
        assert!(r["agent"].is_null());
        assert!(request(&json!({"tool_input": "s"}), "i", 0, 60).is_none());
        let hook =
            json!({"tool_name": "Bash", "tool_input": {"command": "rm -rf x"}, "cwd": "/tmp"});
        let r = request(&hook, "i", 0, 60).unwrap();
        assert_eq!(
            (r["risk"].as_str(), r["agent_name"].as_str()),
            (Some("destructive"), Some("main"))
        );
        assert_eq!(r["cwd"], "/tmp");
    }

    #[test]
    fn test_decisions() {
        let d = |a| decision(a).map(|v| v["hookSpecificOutput"]["decision"].clone());
        assert_eq!(d("allow"), Some(json!({"behavior": "allow"})));
        assert_eq!(d("deny").unwrap()["behavior"], "deny");
        let why = d("{\"behavior\":\"deny\",\"message\":\"no\"}").unwrap();
        assert_eq!(why["message"], "The user denied this: no");
        assert_eq!(d("allow\n"), None);
        assert_eq!(d(""), None);
    }
}
