//! `homund busy`: the work an update would kill, one line each; exit 1 when there is any. What
//! `container/claude-busy` did, with the same lines. Sources: background agents
//! (`claude agents --json --all`), claude-worker runs in flight, and the session's own subagents,
//! whose state is read from their transcript stream: a subagent is finished when its meta file
//! says so, when its last message is the harness's interrupt marker (a stopped one writes no
//! `finished`), or when its last message is an assistant `end_turn` (it ended its turn and no
//! Stop was recorded). A subagent with none of these and a transcript quiet for 10 minutes is
//! noted on stderr and treated as stopped. A probe that cannot run says so and never blocks.

use std::collections::HashSet;
use std::fs;
use std::path::Path;
use std::path::PathBuf;
use std::process::Command;
use std::process::ExitCode;
use std::time::SystemTime;

use serde_json::Value;

const QUIET_S: u64 = 600;

pub struct Env {
    pub claude: String,
    pub proc: PathBuf,
    pub workers: PathBuf,
    pub projects: PathBuf,
    pub sessions: PathBuf,
}

impl Env {
    pub fn from_env() -> Self {
        let var = |key: &str, fallback: &str| {
            std::env::var_os(key).map_or_else(
                || PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(fallback),
                PathBuf::from,
            )
        };
        Self {
            claude: std::env::var("CLAUDE_BUSY_CLAUDE").unwrap_or("claude".into()),
            proc: std::env::var_os("CLAUDE_BUSY_PROC").map_or("/proc".into(), PathBuf::from),
            workers: var("CLAUDE_WORKER_DIR", "claude/.services/workers"),
            projects: var("CLAUDE_BUSY_PROJECTS", ".claude/projects"),
            sessions: var("CLAUDE_BUSY_SESSIONS", ".claude/sessions"),
        }
    }

    fn background(&self) -> Result<Vec<String>, String> {
        let failed = || "could not read `claude agents --json --all`".to_owned();
        let out = Command::new("timeout")
            .args(["20", &self.claude, "agents", "--json", "--all"])
            .output()
            .map_err(|_| failed())?;
        if !out.status.success() {
            return Err(failed());
        }
        let agents: Vec<Value> = serde_json::from_slice(&out.stdout).map_err(|_| failed())?;
        let mut lines = vec![];
        for a in agents {
            let kind = a["kind"].as_str().ok_or_else(failed)?;
            let state = a["state"].as_str();
            if kind == "background" && !matches!(state, Some("done" | "failed" | "stopped")) {
                let name = a["name"]
                    .as_str()
                    .filter(|n| !n.is_empty())
                    .or(a["id"].as_str())
                    .ok_or_else(failed)?;
                lines.push(format!("agent {name} ({})", state.unwrap_or("None")));
            }
        }
        Ok(lines)
    }

    /// Run names of the `claude-worker run <name> ...` processes alive now.
    fn live_workers(&self) -> HashSet<String> {
        let mut names = HashSet::new();
        let Ok(dir) = fs::read_dir(&self.proc) else {
            return names;
        };
        for entry in dir.flatten() {
            let Ok(raw) = fs::read(entry.path().join("cmdline")) else {
                continue;
            };
            let argv: Vec<&[u8]> = raw.split(|b| *b == 0).collect();
            for w in argv.windows(3) {
                let tool = w[0].rsplit(|b| *b == b'/').next().unwrap_or(w[0]);
                if tool == b"claude-worker" && w[1] == b"run" {
                    names.insert(String::from_utf8_lossy(w[2]).into_owned());
                }
            }
        }
        names
    }

    fn workers(&self) -> Result<Vec<String>, String> {
        let ledger = self.workers.join("ledger.jsonl");
        if !ledger.exists() {
            return Ok(vec![]);
        }
        let failed = || format!("could not read {}", ledger.display());
        let text = fs::read_to_string(&ledger).map_err(|_| failed())?;
        let mut open = vec![];
        for line in text.lines().filter(|l| !l.is_empty()) {
            let row: Value = serde_json::from_str(line).map_err(|_| failed())?;
            let name = row["name"].as_str().ok_or_else(failed)?;
            if row.get("exit").ok_or_else(failed)?.is_null() {
                open.push(name.to_owned());
            }
        }
        let live = self.live_workers();
        Ok(open
            .into_iter()
            .filter(|n| live.contains(n))
            .map(|n| format!("worker {n} (claude-worker run)"))
            .collect())
    }

    /// Session ids whose Claude process runs now: sessions/<pid>.json names a pid that exists
    /// with the same start time (files of earlier containers stay).
    fn live_sessions(&self) -> HashSet<String> {
        let mut live = HashSet::new();
        let Ok(dir) = fs::read_dir(&self.sessions) else {
            return live;
        };
        for entry in dir
            .flatten()
            .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
        {
            let Some(info) = fs::read_to_string(entry.path())
                .ok()
                .and_then(|t| serde_json::from_str::<Value>(&t).ok())
            else {
                continue;
            };
            let Some(pid) = info["pid"].as_u64() else {
                continue;
            };
            let Ok(stat) = fs::read_to_string(format!("/proc/{pid}/stat")) else {
                continue;
            };
            let start = stat
                .rsplit_once(')')
                .and_then(|(_, r)| r.split_whitespace().nth(19));
            let want = match &info["procStart"] {
                Value::String(s) => Some(s.clone()),
                Value::Null => None,
                other => Some(other.to_string()),
            };
            if start.map(str::to_owned) == want
                && let Some(id) = info["sessionId"].as_str()
            {
                live.insert(id.to_owned());
            }
        }
        live
    }

    fn subagents(&self) -> Vec<String> {
        let live = self.live_sessions();
        let mut metas = vec![];
        let pattern =
            |p: &Path| fs::read_dir(p).map(|d| d.flatten().map(|e| e.path()).collect::<Vec<_>>());
        for project in pattern(&self.projects).unwrap_or_default() {
            for session in pattern(&project).unwrap_or_default() {
                for f in pattern(&session.join("subagents")).unwrap_or_default() {
                    let name = f
                        .file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into_owned();
                    if name.starts_with("agent-") && name.ends_with(".meta.json") {
                        metas.push((session.clone(), f));
                    }
                }
            }
        }
        metas.sort_by(|a, b| a.1.cmp(&b.1));
        let mut lines = vec![];
        for (session, meta) in metas {
            if !live.contains(
                session
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .as_ref(),
            ) {
                continue; // its session ended: the subagent died with it
            }
            let stem = meta
                .to_string_lossy()
                .trim_end_matches(".meta.json")
                .to_owned();
            let transcript = PathBuf::from(format!("{stem}.jsonl"));
            let Some(info) = fs::read_to_string(&meta)
                .ok()
                .and_then(|t| serde_json::from_str::<Value>(&t).ok())
            else {
                continue;
            };
            let Some(quiet) = fs::metadata(&transcript)
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| SystemTime::now().duration_since(t).ok())
            else {
                continue;
            };
            let name = info["description"]
                .as_str()
                .filter(|d| !d.is_empty())
                .map_or_else(
                    || {
                        transcript
                            .file_stem()
                            .unwrap_or_default()
                            .to_string_lossy()
                            .into_owned()
                    },
                    str::to_owned,
                );
            if info["finished"] == true || ended(&transcript) {
                continue;
            }
            if quiet.as_secs() > QUIET_S {
                eprintln!(
                    "claude-busy: agent {name} quiet {}s, no finish or interrupt record: treated as stopped",
                    quiet.as_secs()
                );
                continue;
            }
            let kind = info["agentType"].as_str().unwrap_or("agent");
            lines.push(format!("agent {name} ({kind} subagent)"));
        }
        lines
    }
}

/// True when the stream's last message record shows the subagent stopped: the harness's
/// interrupt marker as a user record, or an assistant record that ended its turn.
pub fn ended(transcript: &Path) -> bool {
    let Ok(bytes) = fs::read(transcript) else {
        return false;
    };
    let tail = &bytes[bytes.len().saturating_sub(65536)..];
    for row in String::from_utf8_lossy(tail).lines().rev() {
        let Ok(rec) = serde_json::from_str::<Value>(row) else {
            continue;
        };
        let kind = rec["type"].as_str().unwrap_or("");
        if kind != "user" && kind != "assistant" {
            continue;
        }
        let message = &rec["message"];
        return if kind == "assistant" {
            message["stop_reason"] == "end_turn"
        } else {
            let text = match &message["content"] {
                Value::String(s) => s.clone(),
                other => other.to_string(),
            };
            text.contains("[Request interrupted by user")
        };
    }
    false
}

pub fn run() -> ExitCode {
    let env = Env::from_env();
    let mut lines = vec![];
    for probe in [env.background(), env.workers(), Ok(env.subagents())] {
        match probe {
            Ok(found) => lines.extend(found),
            Err(e) => eprintln!("claude-busy: {e}"),
        }
    }
    if lines.is_empty() {
        return ExitCode::SUCCESS;
    }
    println!("{}", lines.join("\n"));
    ExitCode::from(1)
}

#[cfg(test)]
mod test {
    use super::*;

    fn stream(
        name: &str,
        text: &str,
    ) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("homund-busy-{}-{name}.jsonl", std::process::id()));
        fs::write(&path, text).unwrap();
        path
    }

    #[test]
    fn test_stopped_subagent_is_not_left_standing() {
        let interrupted = r#"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#;
        assert!(ended(&stream("int", &format!("{{}}\n{interrupted}\n"))));
        let done = r#"{"type":"assistant","message":{"stop_reason":"end_turn","content":[]}}"#;
        assert!(ended(&stream("done", &format!("{done}\n"))));
    }

    #[test]
    fn test_running_subagent_stays_busy() {
        let tool = r#"{"type":"assistant","message":{"stop_reason":"tool_use","content":[]}}"#;
        assert!(!ended(&stream("tool", &format!("{tool}\n"))));
        let result = r#"{"type":"user","message":{"content":[{"type":"tool_result"}]}}"#;
        assert!(!ended(&stream("res", &format!("{tool}\n{result}\n"))));
        assert!(!ended(&stream("empty", "{}\n")));
    }
}
