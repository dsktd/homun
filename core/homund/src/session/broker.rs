//! `homund session broker <dir> [claude arguments...]`: one long-lived headless `claude -p` on
//! stream-json, what container/session-broker does, with the same files and environment
//! (BROKER_SESSION_FILE, BROKER_SESSION, BROKER_WORKDIR, BROKER_PROMPT, BROKER_FRESH,
//! BROKER_COMPACT, BROKER_ROLE, BROKER_ROTATE_BYTES, BROKER_PERMIT_TIMEOUT, BROKER_STATUSLINE,
//! APPROVE_DIR, COMPACT_DIR). Every line claude prints goes to <dir>/stream.jsonl; each line of
//! the FIFO <dir>/in is a message for it; <dir>/turns indexes the turn ends, and the stream
//! rotates to stream.jsonl.1 only at a turn end, so a rotation asked for mid-turn waits for the
//! turn and drops nothing. Permission prompts become approve cards, `/compact` is sent for the
//! Emacs request while idle, the status line is fed, tasks.json is kept, and claude is started
//! again (--resume) whenever it exits.

use std::collections::HashMap;
use std::fs;
use std::fs::File;
use std::fs::OpenOptions;
use std::io::BufRead;
use std::io::BufReader;
use std::io::Write;
use std::path::Path;
use std::path::PathBuf;
use std::process::Child;
use std::process::ChildStdin;
use std::process::Command;
use std::process::ExitCode;
use std::process::Stdio;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::AtomicI32;
use std::sync::atomic::Ordering;
use std::thread;
use std::time::Duration;
use std::time::Instant;

use serde_json::Map;
use serde_json::Value;
use serde_json::json;

use super::cut;
use super::home;
use super::now;
use super::uuid4;
use super::write_atomic;

/// A new claude drops channel events until its first turn, so a start without a BROKER_PROMPT
/// still opens with one.
pub const FIRST_TURN: &str = "Session started. Reply with one word: ready.";
const METER_EVERY: f64 = 20.0;
const COMPACT_WAIT: f64 = 20.0;
const STREAM_FLAGS: [&str; 12] = [
    "-p",
    "--input-format",
    "stream-json",
    "--output-format",
    "stream-json",
    "--include-partial-messages",
    "--verbose",
    "--replay-user-messages",
    "--forward-subagent-text",
    "--permission-prompt-tool",
    "stdio",
    "",
];

fn env(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.is_empty())
}

fn env_num(
    key: &str,
    fallback: u64,
) -> u64 {
    env(key).and_then(|v| v.parse().ok()).unwrap_or(fallback)
}

fn services(
    key: &str,
    name: &str,
) -> PathBuf {
    env(key).map_or_else(|| home().join("claude/.services").join(name), PathBuf::from)
}

/// The append-only output file with its index of turn ends, rotated between turns.
pub struct Stream {
    path: PathBuf,
    turns: PathBuf,
    rotate: u64,
    file: Mutex<File>,
}

impl Stream {
    pub fn open(
        dir: &Path,
        rotate: u64,
    ) -> std::io::Result<Self> {
        let path = dir.join("stream.jsonl");
        let file = OpenOptions::new().append(true).create(true).open(&path)?;
        Ok(Self {
            turns: dir.join("turns"),
            path,
            rotate,
            file: Mutex::new(file),
        })
    }

    pub fn write(
        &self,
        line: &[u8],
        turn_end: bool,
    ) {
        let mut file = self.file.lock().unwrap();
        let _ = file.write_all(line);
        let _ = file.flush();
        if !turn_end {
            return;
        }
        let size = file.metadata().map_or(0, |m| m.len());
        if size > self.rotate {
            let _ = fs::rename(&self.path, self.path.with_file_name("stream.jsonl.1"));
            if let Ok(f) = OpenOptions::new()
                .append(true)
                .create(true)
                .open(&self.path)
            {
                *file = f;
            }
            let _ = write_atomic(&self.turns, "0\n");
        } else if let Ok(mut index) = OpenOptions::new()
            .append(true)
            .create(true)
            .open(&self.turns)
        {
            let _ = writeln!(index, "{size}");
        }
    }

    /// A line of the broker's own, told apart by its type.
    pub fn note(
        &self,
        subtype: &str,
        fields: Value,
    ) {
        let mut event = Map::new();
        event.insert("type".into(), "broker".into());
        event.insert("subtype".into(), subtype.into());
        event.insert("ts".into(), now().into());
        if let Value::Object(more) = fields {
            event.extend(more);
        }
        let mut line = Value::Object(event).to_string().into_bytes();
        line.push(b'\n');
        self.write(&line, subtype == "exit");
    }
}

/// Python's truth of a JSON value.
fn truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64() != Some(0.0),
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
    }
}

/// One permission prompt: its card in requests/ and the wait for answers/<id>.
pub struct Permit {
    tool: String,
    input: Map<String, Value>,
    agent: Option<Value>,
    id: String,
    file: PathBuf,
    answer: PathBuf,
    timeout: u64,
    cancelled: AtomicBool,
}

impl Permit {
    pub fn new(
        request: &Value,
        role: &str,
        approve: &Path,
        timeout: u64,
    ) -> Self {
        let tool = request
            .get("tool_name")
            .filter(|v| truthy(v))
            .map_or("?".into(), |v| {
                v.as_str().map_or(v.to_string(), str::to_owned)
            });
        let input = request
            .get("input")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        let agent = request
            .get("agent_id")
            .filter(|v| truthy(v))
            .cloned()
            .or_else(|| (role != "manager").then(|| Value::from(role)));
        let id = format!(
            "{}-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos(),
            std::process::id()
        );
        Self {
            tool,
            input,
            agent,
            file: approve.join("requests").join(format!("{id}.json")),
            answer: approve.join("answers").join(&id),
            id,
            timeout,
            cancelled: AtomicBool::new(false),
        }
    }

    pub fn summary(&self) -> String {
        let i = &self.input;
        let found = ["command", "file_path", "url", "pattern"]
            .iter()
            .filter_map(|k| i.get(*k))
            .find(|v| truthy(v));
        let text = match found {
            Some(Value::String(s)) => s.clone(),
            Some(v) => v.to_string(),
            None => Value::Object(i.clone()).to_string(),
        };
        cut(&text, 400).to_owned()
    }

    /// What the approve card reads; long strings cut as the hook cuts them.
    pub fn card(&self) -> Value {
        let shown: Map<String, Value> = self
            .input
            .iter()
            .map(|(k, v)| match v {
                Value::String(s) => (k.clone(), Value::from(cut(s, 4000))),
                _ => (k.clone(), v.clone()),
            })
            .collect();
        let shown = Value::Object(shown);
        let cwd = std::env::current_dir().unwrap_or_default();
        let root = crate::risk::worktree_root(&cwd);
        let input = if shown.to_string().len() <= 6000 {
            shown
        } else {
            json!({})
        };
        json!({
            "id": self.id,
            "tool": self.tool,
            "summary": self.summary(),
            "input": input,
            "agent": self.agent.as_ref().map(|a| json!({"id": a, "type": a})),
            "since": now() as i64,
            "timeout": self.timeout,
            "cwd": cwd,
            "root": root,
            "agent_name": self.agent.as_ref().and_then(Value::as_str).unwrap_or("main"),
            "risk": crate::risk::classify(&self.tool, &input, &cwd, &root).name(),
        })
    }

    /// The decision claude expects, after waiting for the user's answer.
    pub fn decide(&self) -> Value {
        let made = self
            .file
            .parent()
            .map_or(Ok(()), fs::create_dir_all)
            .and_then(|()| write_atomic(&self.file, &self.card().to_string()));
        if let Err(e) = made {
            return json!({"behavior": "deny", "message": format!("Could not ask the user: {e}")});
        }
        let decision = self.wait();
        let _ = fs::remove_file(&self.file);
        decision
    }

    fn wait(&self) -> Value {
        let deadline = Instant::now() + Duration::from_secs(self.timeout);
        while Instant::now() < deadline && !self.cancelled.load(Ordering::SeqCst) {
            let answer = fs::read(&self.answer).unwrap_or_default();
            let answer = String::from_utf8_lossy(&answer[..answer.len().min(100_000)]);
            let answer = answer.trim();
            if answer == "allow" {
                return json!({"behavior": "allow", "updatedInput": self.input});
            }
            if answer == "deny" {
                return json!({"behavior": "deny", "message": "The user denied this in the cockpit"});
            }
            if answer.starts_with('{') {
                return self.custom(answer);
            }
            for _ in 0..10 {
                if self.cancelled.load(Ordering::SeqCst) {
                    break;
                }
                thread::sleep(Duration::from_millis(50));
            }
        }
        if self.cancelled.load(Ordering::SeqCst) {
            return json!({"behavior": "deny", "message": "The prompt was withdrawn"});
        }
        let message = format!(
            "Nobody answered the permission prompt within {} s; it is denied",
            self.timeout
        );
        json!({"behavior": "deny", "message": message})
    }

    fn custom(
        &self,
        answer: &str,
    ) -> Value {
        let Ok(given) = serde_json::from_str::<Value>(answer) else {
            return json!({"behavior": "deny", "message": "The answer was not readable"});
        };
        if given.get("behavior").and_then(Value::as_str) != Some("allow") {
            let message = given
                .get("message")
                .filter(|m| truthy(m))
                .map_or("The user denied this".into(), |m| {
                    m.as_str().map_or(m.to_string(), str::to_owned)
                });
            return json!({"behavior": "deny", "message": message});
        }
        let updated = match given.get("updatedInput") {
            Some(Value::Object(u)) if self.tool == "AskUserQuestion" => {
                let mut merged = self.input.clone();
                merged.extend(u.clone()); // the answers, beside the questions asked
                merged
            }
            Some(Value::Object(u)) => u.clone(),
            _ => self.input.clone(),
        };
        json!({"behavior": "allow", "updatedInput": updated})
    }
}

/// The status line's input, rebuilt from the stream: claude -p runs no status line.
#[derive(Default)]
struct Meter {
    windows: Map<String, Value>,
    model: Option<Value>,
    cost: Option<Value>,
    last: Option<Instant>,
}

impl Meter {
    fn see(
        &mut self,
        event: &Value,
        statusline: &Path,
    ) {
        let kind = event.get("type").and_then(Value::as_str);
        match kind {
            Some("rate_limit_event") => {
                if let Some(Value::Object(w)) = event.pointer("/rate_limit_info/unifiedWindows") {
                    self.windows.extend(w.clone());
                }
            }
            Some("system") if event.get("subtype").and_then(Value::as_str) == Some("init") => {
                self.model = Some(json!({
                    "id": event.get("model"),
                    "version": event.get("claude_code_version"),
                    "cwd": event.get("cwd"),
                }));
                return; // the next rate limit or result takes the sample
            }
            Some("result") if !event.get("parent_tool_use_id").is_some_and(truthy) => {
                self.cost = event.get("total_cost_usd").cloned();
            }
            _ => return,
        }
        if self
            .last
            .is_none_or(|t| t.elapsed().as_secs_f64() >= METER_EVERY)
        {
            self.last = Some(Instant::now());
            self.feed(event.get("session_id"), statusline);
        }
    }

    fn limit(
        &self,
        name: &str,
    ) -> Value {
        let window = self.windows.get(name);
        let used = window
            .and_then(|w| w.get("utilization"))
            .and_then(Value::as_f64);
        json!({
            "used_percentage": used.map(|u| (u * 100.0).round() as i64),
            "resets_at": window.and_then(|w| w.get("resetsAt")),
        })
    }

    fn feed(
        &self,
        session: Option<&Value>,
        statusline: &Path,
    ) {
        let model = self.model.clone().unwrap_or_default();
        let status = json!({
            "session_id": session,
            "model": {"id": model.get("id")},
            "version": model.get("version"),
            "cwd": model.get("cwd"),
            "rate_limits": {"five_hour": self.limit("five_hour"), "seven_day": self.limit("seven_day")},
            "cost": {"total_cost_usd": self.cost},
        });
        let Ok(mut child) = Command::new("sh")
            .arg(statusline)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        else {
            return; // the samples are advisory
        };
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(status.to_string().as_bytes());
        }
        let deadline = Instant::now() + Duration::from_secs(10);
        while matches!(child.try_wait(), Ok(None)) {
            if Instant::now() >= deadline {
                let _ = child.kill();
                break;
            }
            thread::sleep(Duration::from_millis(20));
        }
        let _ = child.wait();
    }
}

/// The claude process of one session, restarted whenever it exits.
pub struct Session {
    dir: PathBuf,
    arguments: Vec<String>,
    pub stream: Stream,
    role: String,
    id_file: PathBuf,
    prompt: String,
    fresh: Option<PathBuf>,
    approve: PathBuf,
    statusline: PathBuf,
    permit_timeout: u64,
    child: Mutex<Option<Child>>,
    stdin: Mutex<Option<ChildStdin>>,
    permits: Mutex<HashMap<String, Arc<Permit>>>,
    seen: Mutex<HashMap<String, f64>>,
    stopping: AtomicBool,
    busy: AtomicBool,
    meter: Mutex<Meter>,
}

impl Session {
    pub fn new(
        dir: &Path,
        arguments: Vec<String>,
    ) -> std::io::Result<Self> {
        let rotate = env_num("BROKER_ROTATE_BYTES", 20 * 1024 * 1024);
        Ok(Self {
            stream: Stream::open(dir, rotate)?,
            dir: dir.to_owned(),
            arguments,
            role: env("BROKER_ROLE")
                .or_else(|| env("CLAUDE_ROLE"))
                .unwrap_or_default(),
            id_file: env("BROKER_SESSION_FILE").map_or_else(|| dir.join("session"), PathBuf::from),
            prompt: env("BROKER_PROMPT").unwrap_or(FIRST_TURN.into()),
            fresh: env("BROKER_FRESH").map(PathBuf::from),
            approve: services("APPROVE_DIR", "approve"),
            statusline: env("BROKER_STATUSLINE")
                .map_or_else(|| "/opt/homun/statusline.sh".into(), PathBuf::from),
            permit_timeout: env_num("BROKER_PERMIT_TIMEOUT", 300),
            child: Mutex::new(None),
            stdin: Mutex::new(None),
            permits: Mutex::new(HashMap::new()),
            seen: Mutex::new(HashMap::new()),
            stopping: AtomicBool::new(false),
            busy: AtomicBool::new(false),
            meter: Mutex::new(Meter::default()),
        })
    }

    pub fn busy(&self) -> bool {
        self.busy.load(Ordering::SeqCst)
    }

    /// The id to run: the file's, else BROKER_SESSION, else a new one kept in the file.
    fn session_id(&self) -> String {
        let found = fs::read_to_string(&self.id_file)
            .unwrap_or_default()
            .trim()
            .to_owned();
        if !found.is_empty() {
            return found;
        }
        if let Some(given) = env("BROKER_SESSION") {
            return given;
        }
        let new = uuid4();
        let _ = fs::write(&self.id_file, format!("{new}\n"));
        new
    }

    /// Take the fresh marker: the next session_id() is a new session.
    fn renew(&self) {
        let Some(fresh) = &self.fresh else { return };
        if !fresh.exists() {
            return;
        }
        let _ = fs::remove_file(fresh);
        let _ = fs::write(&self.id_file, format!("{}\n", uuid4()));
        self.stream.note("fresh", json!({"reason": "role-recycle"}));
    }

    /// The command line, and whether it resumes a session that has turns.
    fn command(&self) -> (Vec<String>, bool) {
        let session = self.session_id();
        let name = format!("{session}.jsonl");
        let known = fs::read_dir(home().join(".claude/projects"))
            .into_iter()
            .flatten()
            .flatten()
            .any(|d| d.path().join(&name).is_file());
        let pick = if known { "--resume" } else { "--session-id" };
        // The caller's arguments first: a role's health check looks for `claude --name`
        let mut cmd = self.arguments.clone();
        cmd.extend(
            STREAM_FLAGS
                .iter()
                .filter(|f| !f.is_empty())
                .map(|f| (*f).to_owned()),
        );
        cmd.extend([pick.to_owned(), session]);
        (cmd, known)
    }

    /// The broker's own, without what marks a process as running inside another session. The
    /// role's hooks and channel servers accept the claude whose parent is CLAUDE_ROLE_PID, so
    /// that is the broker; HOMUN_HEADLESS tells the permission hook that prompts are answered here.
    fn environment(&self) -> Vec<(String, String)> {
        let inside = [
            "CLAUDECODE",
            "CLAUDE_CODE_ENTRYPOINT",
            "CLAUDE_CODE_SSE_PORT",
            "BROKER_",
        ];
        let mut env: Vec<(String, String)> = std::env::vars()
            .filter(|(k, _)| !inside.iter().any(|p| k.starts_with(p)))
            .filter(|(k, _)| k != "HOMUN_HEADLESS" && k != "CLAUDE_ROLE" && k != "CLAUDE_ROLE_PID")
            .collect();
        env.push(("HOMUN_HEADLESS".into(), "1".into()));
        if !self.role.is_empty() {
            env.push(("CLAUDE_ROLE".into(), self.role.clone()));
            env.push(("CLAUDE_ROLE_PID".into(), std::process::id().to_string()));
        } else {
            for key in ["CLAUDE_ROLE", "CLAUDE_ROLE_PID"] {
                if let Ok(v) = std::env::var(key) {
                    env.push((key.into(), v));
                }
            }
        }
        env
    }

    pub fn send(
        &self,
        message: &Value,
    ) {
        let mut stdin = self.stdin.lock().unwrap();
        let Some(pipe) = stdin.as_mut() else { return };
        if message.get("type").and_then(Value::as_str) == Some("user") {
            self.busy.store(true, Ordering::SeqCst);
        }
        let mut line = message.to_string().into_bytes();
        line.push(b'\n');
        let _ = pipe.write_all(&line).and_then(|()| pipe.flush());
    }

    /// Hand one line of the FIFO to claude.
    pub fn say(
        &self,
        line: &str,
    ) {
        let mut message = if line.starts_with('{') {
            match serde_json::from_str::<Value>(line) {
                Ok(m @ Value::Object(_))
                    if matches!(
                        m.get("type").and_then(Value::as_str),
                        Some("user" | "control_request")
                    ) =>
                {
                    m
                }
                _ => {
                    self.stream.note("refused", json!({"line": cut(line, 200)}));
                    return;
                }
            }
        } else if line == "/interrupt" {
            json!({"type": "control_request", "request": {"subtype": "interrupt"}})
        } else if !line.is_empty() {
            json!({"type": "user", "message": {"role": "user", "content": line}})
        } else {
            return;
        };
        if message["type"] == "control_request" && message.get("request_id").is_none() {
            message["request_id"] = Value::from(uuid4().replace('-', ""));
        }
        self.send(&message);
    }

    /// Answer one can_use_tool request; runs in a thread of its own.
    fn permit(
        &self,
        request_id: Value,
        request: &Value,
    ) {
        let key = request_id.to_string();
        let permit = Arc::new(Permit::new(
            request,
            &self.role,
            &self.approve,
            self.permit_timeout,
        ));
        self.permits
            .lock()
            .unwrap()
            .insert(key.clone(), permit.clone());
        let fields = json!({"id": permit.id, "tool": permit.tool, "summary": permit.summary()});
        self.stream.note("asked", fields);
        let decision = permit.decide();
        self.permits.lock().unwrap().remove(&key);
        let fields = json!({"request_id": request_id, "tool": permit.tool, "decision": decision});
        self.stream.note("permission", fields);
        let answer = json!({"subtype": "success", "request_id": request_id, "response": decision});
        self.send(&json!({"type": "control_response", "response": answer}));
    }

    /// Keep one line of claude's output and act on those meant for its host.
    fn handle(
        self: &Arc<Self>,
        line: &[u8],
    ) {
        let has = |needle: &[u8]| line.windows(needle.len()).any(|w| w == needle);
        let mut kind: &str = "";
        for name in [
            "result",
            "control_request",
            "control_cancel_request",
            "system",
            "rate_limit_event",
        ] {
            if has(format!("\"type\":\"{name}\"").as_bytes()) {
                kind = name;
            }
        }
        let turn_end = kind == "result" && !has(b"\"parent_tool_use_id\":\"");
        self.stream.write(line, turn_end);
        if turn_end {
            self.busy.store(false, Ordering::SeqCst);
        }
        if kind.is_empty() {
            return;
        }
        let Ok(event) = serde_json::from_slice::<Value>(line) else {
            return;
        };
        self.meter.lock().unwrap().see(&event, &self.statusline);
        let typ = event.get("type").and_then(Value::as_str);
        if typ == Some("control_request") {
            let request = event.get("request").cloned().unwrap_or_default();
            if request.get("subtype").and_then(Value::as_str) == Some("can_use_tool") {
                let id = event.get("request_id").cloned().unwrap_or_default();
                let me = Arc::clone(self);
                thread::spawn(move || me.permit(id, &request));
            }
        } else if typ == Some("control_cancel_request") {
            let key = event
                .get("request_id")
                .cloned()
                .unwrap_or_default()
                .to_string();
            if let Some(p) = self.permits.lock().unwrap().get(&key) {
                p.cancelled.store(true, Ordering::SeqCst);
            }
        } else if event.get("subtype").and_then(Value::as_str) == Some("background_tasks_changed") {
            let tasks = event
                .get("tasks")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            self.keep_tasks(&tasks, event.get("session_id").cloned().unwrap_or_default());
        }
    }

    /// Write tasks.json: claude's list, each task with the time it was first seen.
    fn keep_tasks(
        &self,
        tasks: &[Value],
        session: Value,
    ) {
        let t = now();
        let mut seen = self.seen.lock().unwrap();
        let key = |task: &Value| task.get("task_id").cloned().unwrap_or_default().to_string();
        *seen = tasks
            .iter()
            .map(|task| (key(task), *seen.get(&key(task)).unwrap_or(&t)))
            .collect();
        let listed: Vec<Value> = tasks
            .iter()
            .map(|task| {
                let mut task = task.clone();
                if let Value::Object(o) = &mut task {
                    o.insert(
                        "started".into(),
                        seen[&key(&Value::Object(o.clone()))].into(),
                    );
                }
                task
            })
            .collect();
        let text = json!({"ts": t, "session": session, "tasks": listed}).to_string();
        let _ = write_atomic(&self.dir.join("tasks.json"), &text); // advisory
    }

    fn wait_child(&self) -> i32 {
        loop {
            if let Some(child) = self.child.lock().unwrap().as_mut() {
                match child.try_wait() {
                    Ok(Some(status)) => return exit_code(status),
                    Ok(None) => {}
                    Err(_) => return -1,
                }
            } else {
                return -1;
            }
            thread::sleep(Duration::from_millis(20));
        }
    }

    pub fn run_forever(self: &Arc<Self>) {
        while !self.stopping.load(Ordering::SeqCst) {
            self.renew();
            let (command, resumed) = self.command();
            let mut cmd = Command::new("claude");
            cmd.args(&command)
                .env_clear()
                .envs(self.environment())
                .stdin(Stdio::piped())
                .stdout(Stdio::piped());
            if let Some(dir) = env("BROKER_WORKDIR") {
                cmd.current_dir(dir);
            }
            let stdout = match cmd.spawn() {
                Ok(mut child) => {
                    *self.stdin.lock().unwrap() = child.stdin.take();
                    let stdout = child.stdout.take();
                    *self.child.lock().unwrap() = Some(child);
                    stdout
                }
                Err(e) => {
                    self.stream
                        .note("exit", json!({"code": 127, "error": e.to_string()}));
                    thread::sleep(Duration::from_secs(2));
                    continue;
                }
            };
            if !resumed {
                // a resume is no first start
                let first =
                    json!({"type": "user", "message": {"role": "user", "content": self.prompt}});
                self.send(&first);
            }
            if let Some(stdout) = stdout {
                let mut reader = BufReader::new(stdout);
                let mut line = Vec::new();
                while reader.read_until(b'\n', &mut line).is_ok_and(|n| n > 0) {
                    self.handle(&line);
                    line.clear();
                }
            }
            for permit in self.permits.lock().unwrap().values() {
                permit.cancelled.store(true, Ordering::SeqCst);
            }
            self.keep_tasks(&[], Value::Null);
            self.busy.store(false, Ordering::SeqCst);
            let code = self.wait_child();
            *self.stdin.lock().unwrap() = None;
            self.stream.note("exit", json!({"code": code}));
            if !self.stopping.load(Ordering::SeqCst) {
                thread::sleep(Duration::from_secs(2));
            }
        }
    }

    /// End claude on its own terms: its input closes, then it is told, then killed.
    pub fn stop(&self) {
        self.stopping.store(true, Ordering::SeqCst);
        let pid = match self.child.lock().unwrap().as_mut() {
            Some(c) => match c.try_wait() {
                Ok(None) => c.id(),
                _ => return,
            },
            None => return,
        };
        *self.stdin.lock().unwrap() = None;
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            match self.child.lock().unwrap().as_mut().map(Child::try_wait) {
                Some(Ok(None)) => {}
                _ => return,
            }
            thread::sleep(Duration::from_millis(20));
        }
        // SAFETY: a plain kill(2) of our own child, which has not been reaped yet.
        unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM) };
    }
}

fn exit_code(status: std::process::ExitStatus) -> i32 {
    use std::os::unix::process::ExitStatusExt;
    status
        .code()
        .unwrap_or_else(|| -status.signal().unwrap_or(0))
}

/// The Emacs compact request, as compact-relay takes it: the newest fresh one, once.
pub struct Compact {
    dir: PathBuf,
    seen: Option<String>,
    pending: Option<i64>,
}

impl Compact {
    pub fn new(dir: PathBuf) -> Self {
        let mut c = Self {
            dir,
            seen: None,
            pending: None,
        };
        c.seen = c.read(); // a request left from before this start is not obeyed
        c
    }

    fn read(&self) -> Option<String> {
        let bytes = fs::read(self.dir.join("emacs-request/request")).ok()?;
        Some(cut(&String::from_utf8_lossy(&bytes), 64).trim().to_owned())
    }

    fn answer(
        &self,
        stamp: i64,
        text: &str,
    ) {
        let _ = write_atomic(&self.dir.join("emacs-result"), &format!("{stamp} {text}\n"));
    }

    pub fn poll(
        &mut self,
        session: &Session,
    ) {
        let line = self.read();
        if line.is_some() && line != self.seen {
            self.seen.clone_from(&line);
            let line = line.unwrap_or_default();
            let word: Vec<&str> = line.split(' ').collect();
            if let [stamp, "compact"] = word[..]
                && !stamp.is_empty()
                && stamp.bytes().all(|b| b.is_ascii_digit())
                && let Ok(stamp) = stamp.parse::<i64>()
            {
                if (0.0..=60.0).contains(&(now() - stamp as f64)) {
                    self.pending = Some(stamp);
                } else {
                    self.answer(stamp, "refused: stale request");
                }
            }
        }
        let Some(stamp) = self.pending else { return };
        if !session.busy() {
            self.pending = None;
            session.say("/compact");
            self.answer(stamp, "ok");
        } else if now() - stamp as f64 > COMPACT_WAIT {
            self.pending = None;
            self.answer(stamp, "refused: The session is busy");
        }
    }
}

/// Hand every line written to the FIFO to the session; opened read-write so it never ends.
fn read_turns(
    fifo: &Path,
    session: &Session,
) -> std::io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::FileTypeExt;
    if !fs::metadata(fifo).is_ok_and(|m| m.file_type().is_fifo()) {
        let _ = fs::remove_file(fifo);
        let path = std::ffi::CString::new(fifo.as_os_str().as_bytes())?;
        // SAFETY: mkfifo(3) on a NUL-terminated path.
        if unsafe { libc::mkfifo(path.as_ptr(), 0o600) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
    }
    let file = OpenOptions::new().read(true).write(true).open(fifo)?;
    let mut reader = BufReader::new(file);
    let mut line = Vec::new();
    while reader.read_until(b'\n', &mut line)? > 0 {
        session.say(String::from_utf8_lossy(&line).trim());
        line.clear();
    }
    Ok(())
}

static SIGNALLED: AtomicI32 = AtomicI32::new(0);

extern "C" fn on_signal(number: libc::c_int) {
    SIGNALLED.store(number, Ordering::SeqCst);
}

pub fn main(args: &[String]) -> ExitCode {
    let Some(dir) = args
        .first()
        .filter(|a| !matches!(a.as_str(), "help" | "-h" | "--help"))
    else {
        println!("{}", super::HELP);
        return if args.is_empty() {
            ExitCode::from(2)
        } else {
            ExitCode::SUCCESS
        };
    };
    let dir = PathBuf::from(dir);
    let session =
        match fs::create_dir_all(&dir).and_then(|()| Session::new(&dir, args[1..].to_vec())) {
            Ok(s) => Arc::new(s),
            Err(e) => {
                eprintln!("homund session broker: {}: {e}", dir.display());
                return ExitCode::FAILURE;
            }
        };
    for number in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
        // SAFETY: the handler only stores into an atomic.
        unsafe { libc::signal(number, on_signal as *const () as libc::sighandler_t) };
    }
    let me = Arc::clone(&session);
    thread::spawn(move || {
        while SIGNALLED.load(Ordering::SeqCst) == 0 {
            thread::sleep(Duration::from_millis(50));
        }
        me.stop();
    });
    if std::env::var("BROKER_COMPACT").as_deref() == Ok("1") {
        let me = Arc::clone(&session);
        thread::spawn(move || {
            let mut compact = Compact::new(services("COMPACT_DIR", "compact"));
            loop {
                compact.poll(&me);
                thread::sleep(Duration::from_secs(1));
            }
        });
    }
    let me = Arc::clone(&session);
    let fifo = dir.join("in");
    thread::spawn(move || {
        if let Err(e) = read_turns(&fifo, &me) {
            eprintln!("homund session broker: {}: {e}", fifo.display());
        }
    });
    session.run_forever();
    ExitCode::SUCCESS
}
