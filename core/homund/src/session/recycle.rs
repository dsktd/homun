//! `homund session recycle <role> [idle [min]]`: end an idle standing role session so its next
//! start is fresh, what container/role-recycle does. When the role's pinned transcript
//! (~/.claude/<role>-session) has not changed for `idle` seconds (600), its last assistant message
//! ended its turn (end_turn), that turn's context was at least `min` tokens (40000) and the
//! session has answered more than its first prompt (counted in prompts, not end_turn lines), it
//! writes ~/claude/.services/<role>/fresh and sends SIGTERM to the role's claude (the `claude`
//! whose parent is its CLAUDE_ROLE_PID). Prints one line when it recycles; silent otherwise.
//! Never touches the manager. HOMUN_PROC names another /proc, for tests.

use std::fs;
use std::path::Path;
use std::path::PathBuf;
use std::process::ExitCode;

use serde_json::Value;

use super::home;

/// Why a session is left alone, or the context size of the one to recycle.
#[derive(Debug, PartialEq)]
pub enum Verdict {
    Leave,
    Recycle { id: String, age: u64, ctx: u64 },
}

fn bad_name(s: &str) -> bool {
    s.is_empty() || s.contains('/') || s.starts_with('.')
}

fn tokens(usage: &Value) -> u64 {
    [
        "input_tokens",
        "cache_read_input_tokens",
        "cache_creation_input_tokens",
    ]
    .iter()
    .map(|k| usage.get(*k).and_then(Value::as_u64).unwrap_or(0))
    .sum()
}

/// Every line as JSON, or None when one is not (jq -s fails then, and the script leaves).
fn parse_all(text: &str) -> Option<Vec<Value>> {
    text.lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| serde_json::from_str(l).ok())
        .collect()
}

fn prompted(entry: &Value) -> bool {
    if entry.get("type").and_then(Value::as_str) != Some("user")
        || entry.get("isSidechain") == Some(&Value::Bool(true))
    {
        return false;
    }
    match entry.pointer("/message/content") {
        Some(Value::String(_)) => true,
        Some(Value::Array(blocks)) => blocks
            .iter()
            .any(|b| b.get("type").and_then(Value::as_str) == Some("text")),
        _ => false,
    }
}

/// The decision on the role's transcript, without looking for its process.
pub fn judge(
    claude: &Path,
    role: &str,
    idle: u64,
    min: u64,
    now: u64,
) -> Verdict {
    let Ok(id) = fs::read_to_string(claude.join(format!("{role}-session"))) else {
        return Verdict::Leave;
    };
    let id = id.trim_end_matches('\n').to_owned();
    if bad_name(&id) {
        return Verdict::Leave;
    }
    let name = format!("{id}.jsonl");
    let mut found: Vec<PathBuf> = fs::read_dir(claude.join("projects"))
        .into_iter()
        .flatten()
        .flatten()
        .map(|d| d.path().join(&name))
        .filter(|p| p.is_file())
        .collect();
    found.sort();
    let Some(t) = found.first() else {
        return Verdict::Leave;
    };
    let mtime = fs::metadata(t)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(now, |d| d.as_secs());
    let age = now.saturating_sub(mtime);
    if age < idle {
        return Verdict::Leave;
    }
    let Ok(text) = fs::read_to_string(t) else {
        return Verdict::Leave;
    };
    let lines: Vec<&str> = text.lines().collect();
    let last200 = lines[lines.len().saturating_sub(200)..].join("\n");
    let Some(recent) = parse_all(&last200) else {
        return Verdict::Leave;
    };
    let last = recent
        .iter()
        .rev()
        .find(|e| e.get("type").and_then(Value::as_str) == Some("assistant"));
    let Some(message) = last.and_then(|e| e.get("message")) else {
        return Verdict::Leave;
    };
    if message.get("stop_reason").and_then(Value::as_str) != Some("end_turn") {
        return Verdict::Leave;
    }
    let ctx = tokens(message.get("usage").unwrap_or(&Value::Null));
    if ctx < min {
        return Verdict::Leave;
    }
    // Prompts, not end_turn lines: one turn writes several of those.
    let Some(all) = parse_all(&text) else {
        return Verdict::Leave;
    };
    if all.iter().filter(|e| prompted(e)).count() <= 1 {
        return Verdict::Leave;
    }
    Verdict::Recycle { id, age, ctx }
}

/// The role's claude: comm `claude`, CLAUDE_ROLE=<role>, its parent its CLAUDE_ROLE_PID.
pub fn find(
    proc: &Path,
    role: &str,
) -> Option<u32> {
    let want = format!("CLAUDE_ROLE={role}");
    let mut pids: Vec<u32> = fs::read_dir(proc)
        .ok()?
        .flatten()
        .filter_map(|d| d.file_name().to_str()?.parse().ok())
        .collect();
    pids.sort_unstable();
    pids.into_iter().find(|pid| {
        let dir = proc.join(pid.to_string());
        if fs::read_to_string(dir.join("comm"))
            .unwrap_or_default()
            .trim_end()
            != "claude"
        {
            return false;
        }
        let env = fs::read(dir.join("environ")).unwrap_or_default();
        let env: Vec<&[u8]> = env.split(|&b| b == 0).collect();
        if !env.contains(&want.as_bytes()) {
            return false;
        }
        let parent = env
            .iter()
            .find_map(|e| e.strip_prefix(b"CLAUDE_ROLE_PID="))
            .map(|p| String::from_utf8_lossy(p).into_owned())
            .unwrap_or_default();
        let stat = fs::read_to_string(dir.join("stat")).unwrap_or_default();
        let ppid = stat
            .rsplit_once(')')
            .and_then(|(_, r)| r.split_whitespace().nth(1))
            .unwrap_or("");
        !ppid.is_empty() && ppid == parent
    })
}

pub fn main(args: &[String]) -> ExitCode {
    let role = args.first().map_or("", String::as_str);
    if bad_name(role) || role == "manager" {
        return ExitCode::from(2);
    }
    let number = |i: usize, d: u64| args.get(i).and_then(|v| v.parse().ok()).unwrap_or(d);
    let (idle, min) = (number(1, 600), number(2, 40000));
    let now = super::now() as u64;
    let Verdict::Recycle { id, age, ctx } = judge(&home().join(".claude"), role, idle, min, now)
    else {
        return ExitCode::SUCCESS;
    };
    let proc = std::env::var_os("HOMUN_PROC").map_or("/proc".into(), PathBuf::from);
    let Some(pid) = find(&proc, role) else {
        return ExitCode::SUCCESS;
    };
    let dir = home().join("claude/.services").join(role);
    if fs::create_dir_all(&dir)
        .and_then(|()| fs::write(dir.join("fresh"), ""))
        .is_err()
    {
        return ExitCode::FAILURE;
    }
    // SAFETY: kill(2) with a pid read from /proc.
    if unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM) } != 0 {
        return ExitCode::FAILURE;
    }
    println!(
        "{now} role-recycle: {role} idle {age}s at {ctx} tokens: session {id} ended, next start fresh"
    );
    ExitCode::SUCCESS
}

#[cfg(test)]
mod tests {
    use super::*;

    fn home(
        tag: &str,
        lines: &[Value],
    ) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("homund-recycle-{}-{tag}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("projects/p")).unwrap();
        fs::write(dir.join("coach-session"), "abc\n").unwrap();
        let text: Vec<String> = lines.iter().map(Value::to_string).collect();
        fs::write(dir.join("projects/p/abc.jsonl"), text.join("\n") + "\n").unwrap();
        dir
    }

    fn user(text: &str) -> Value {
        serde_json::json!({"type": "user", "message": {"content": text}})
    }

    fn end(input: u64) -> Value {
        serde_json::json!({"type": "assistant", "message": {"stop_reason": "end_turn", "usage": {"input_tokens": input}}})
    }

    #[test]
    fn first_prompt_alone_is_left() {
        let dir = home("one", &[user("hi"), end(50000), end(50000)]);
        assert_eq!(judge(&dir, "coach", 0, 40000, u64::MAX / 2), Verdict::Leave);
    }

    #[test]
    fn second_prompt_recycles() {
        let dir = home("two", &[user("hi"), end(1), user("again"), end(50000)]);
        let v = judge(&dir, "coach", 0, 40000, u64::MAX / 2);
        assert!(matches!(v, Verdict::Recycle { ctx: 50000, .. }), "{v:?}");
    }

    #[test]
    fn small_or_busy_is_left() {
        let dir = home("small", &[user("a"), user("b"), end(100), user("c")]);
        assert_eq!(judge(&dir, "coach", 0, 40000, u64::MAX / 2), Verdict::Leave);
    }
}
