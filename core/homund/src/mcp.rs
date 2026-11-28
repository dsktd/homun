//! `homund mcp [<tools.toml>]`: the tools of `tools.toml` as an MCP server on stdio (M7.1). A
//! call is checked against the tool's typed fields (an invalid one fails naming the field), then
//! forwarded to the Emacs handler as the constant form `(homun-rpc)` with the entry and its
//! `key value` words, through the logged eval wrapper, as `emacs.py` does.

use std::io::BufRead;
use std::io::Write;
use std::path::Path;
use std::process::Command;
use std::process::Stdio;
use std::time::Duration;
use std::time::Instant;

use anyhow::Context;
use anyhow::Result;
use serde::Deserialize;
use serde_json::Map;
use serde_json::Value;
use serde_json::json;

const WRAPPER: &str = "/opt/homun/homun-eval";
const TIMEOUT: Duration = Duration::from_secs(20);
const INSTRUCTIONS: &str = "Typed calls into the cockpit's Emacs daemon, one tool per entry of its API registry (the same entries as the homun-emacs command). Prefer these over emacsclient --eval.";

#[derive(Deserialize)]
struct File {
    tool: Vec<Tool>,
}

#[derive(Deserialize)]
pub struct Tool {
    pub name: String,
    pub doc: String,
    #[serde(default)]
    pub caller: bool,
    #[serde(default)]
    arg: Vec<Arg>,
}

#[derive(Deserialize)]
struct Arg {
    key: String,
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    required: bool,
    default: Option<Value>,
    max: Option<i64>,
    choices: Option<Vec<String>>,
}

pub fn load(path: &Path) -> Result<Vec<Tool>> {
    let text = std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    Ok(toml::from_str::<File>(&text)
        .with_context(|| format!("parse {}", path.display()))?
        .tool)
}

fn symbol(text: &str) -> bool {
    let mut chars = text.chars();
    chars.next().is_some_and(|c| c.is_ascii_lowercase())
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

impl Arg {
    fn property(&self) -> Value {
        if self.kind == "json" {
            return json!({"description": "a JSON value (object or array)"});
        }
        let json_type = match self.kind.as_str() {
            "int" => "integer",
            "bool" => "boolean",
            _ => "string",
        };
        let mut out = json!({ "type": json_type });
        match self.kind.as_str() {
            "enum" => out["enum"] = json!(self.choices),
            "symbol" => out["pattern"] = json!("^[a-z][a-z0-9-]*$"),
            "data" => out["description"] = json!("Lisp data as text, e.g. (:value 1.0) or t"),
            _ => {}
        }
        if let Some(max) = self.max {
            out["maximum"] = json!(max);
        }
        if let Some(default) = &self.default {
            out["default"] = default.clone();
        }
        out
    }

    /// The word this value travels as, or why it is not valid.
    fn word(
        &self,
        value: &Value,
    ) -> std::result::Result<String, String> {
        let word = match (self.kind.as_str(), value) {
            ("json", Value::Object(_) | Value::Array(_)) => value.to_string(),
            ("json", Value::String(text)) => text.clone(),
            ("int", v) if v.is_i64() || v.as_f64().is_some_and(|f| f.fract() == 0.0) => {
                let n = v
                    .as_i64()
                    .unwrap_or_else(|| v.as_f64().unwrap_or(0.0) as i64);
                if let Some(max) = self.max.filter(|max| n > *max) {
                    return Err(format!("{n} is above the maximum {max}"));
                }
                n.to_string()
            }
            ("bool", Value::Bool(b)) => (if *b { "yes" } else { "no" }).to_string(),
            ("enum", Value::String(text)) => {
                let choices = self.choices.clone().unwrap_or_default();
                if !choices.contains(text) {
                    return Err(format!("must be one of {}", choices.join("|")));
                }
                text.clone()
            }
            ("symbol", Value::String(text)) => {
                if !symbol(text) {
                    return Err("must match ^[a-z][a-z0-9-]*$".to_string());
                }
                text.clone()
            }
            ("string" | "data", Value::String(text)) => text.clone(),
            (kind, _) => return Err(format!("must be {kind}")),
        };
        if word.is_empty() {
            Err("empty value".to_string())
        } else {
            Ok(word)
        }
    }
}

impl Tool {
    pub fn mcp_name(&self) -> String {
        self.name.replace(' ', "_")
    }

    fn described(&self) -> Value {
        let properties: Map<String, Value> = self
            .arg
            .iter()
            .map(|a| (a.key.clone(), a.property()))
            .collect();
        let mut schema =
            json!({"type": "object", "properties": properties, "additionalProperties": false});
        let required: Vec<&str> = self
            .arg
            .iter()
            .filter(|a| a.required)
            .map(|a| a.key.as_str())
            .collect();
        if !required.is_empty() {
            schema["required"] = json!(required);
        }
        json!({"name": self.mcp_name(), "description": self.doc, "inputSchema": schema})
    }

    /// The call as words, or `field: reason` for the first invalid field.
    pub fn words(
        &self,
        given: &Map<String, Value>,
        role: &str,
    ) -> std::result::Result<Vec<String>, String> {
        let mut words: Vec<String> = self.name.split(' ').map(str::to_string).collect();
        for key in given.keys() {
            if key == "caller" && self.caller {
                return Err("caller: filled in by the server".to_string());
            }
            if !self.arg.iter().any(|a| &a.key == key) {
                return Err(format!("{key}: no such field"));
            }
        }
        for arg in self.arg.iter().filter(|a| a.required) {
            if given.get(&arg.key).is_none_or(Value::is_null) {
                return Err(format!("{}: required", arg.key));
            }
        }
        for (key, value) in given.iter().filter(|(_, v)| !v.is_null()) {
            let arg = self
                .arg
                .iter()
                .find(|a| &a.key == key)
                .ok_or_else(|| format!("{key}: no such field"))?;
            words.push(key.clone());
            words.push(arg.word(value).map_err(|why| format!("{key}: {why}"))?);
        }
        if self.caller {
            words.extend(["caller".to_string(), role.to_string()]);
        }
        Ok(words)
    }
}

struct Daemon {
    socket: String,
    wrapper: String,
}

impl Daemon {
    fn new() -> Self {
        let home = std::env::var("HOME").unwrap_or_default();
        Daemon {
            socket: format!("{home}/claude/.services/emacs/socket"),
            wrapper: std::env::var("HOMUN_EVAL_WRAPPER").unwrap_or_else(|_| WRAPPER.to_string()),
        }
    }

    fn call(
        &self,
        words: &[String],
    ) -> (bool, String) {
        if !Path::new(&self.socket).exists() {
            return (false, format!("no server at {}", self.socket));
        }
        let mut cmd = if Path::new(&self.wrapper).exists() {
            let mut c = Command::new("python3");
            c.args(["-I", &self.wrapper]);
            c
        } else {
            Command::new("emacsclient")
        };
        cmd.args(["-s", &self.socket, "--eval", "(homun-rpc)"]);
        if words.iter().any(|w| w.starts_with('-')) {
            cmd.arg("--");
        }
        cmd.args(words).env("HOMUN_EVAL_KIND", "rpc");
        let Ok(mut child) = cmd.stdout(Stdio::piped()).stderr(Stdio::piped()).spawn() else {
            return (false, "emacsclient failed: cannot start".to_string());
        };
        let started = Instant::now();
        loop {
            match child.try_wait() {
                Ok(Some(_)) => break,
                Ok(None) if started.elapsed() > TIMEOUT => {
                    let _ = child.kill();
                    return (false, "emacsclient failed: timed out".to_string());
                }
                Ok(None) => std::thread::sleep(Duration::from_millis(5)),
                Err(e) => return (false, format!("emacsclient failed: {e}")),
            }
        }
        let Ok(out) = child.wait_with_output() else {
            return (false, "emacsclient failed".to_string());
        };
        let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !out.status.success()
            || !(text.len() >= 2 && text.starts_with('"') && text.ends_with('"'))
        {
            let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
            return (
                false,
                format!(
                    "emacsclient failed: {}",
                    if err.is_empty() { text } else { err }
                ),
            );
        }
        let text = unescape(&text[1..text.len() - 1]);
        let (head, body) = text.split_once('\n').unwrap_or((&text, ""));
        if head == "ok" {
            (true, body.to_string())
        } else {
            (false, format!("{}: {body}", head.get(4..).unwrap_or("")))
        }
    }
}

fn unescape(text: &str) -> String {
    let mut out = String::new();
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('f') => out.push('\x0c'),
            Some('e') => out.push('\x1b'),
            Some(other) => out.push(other),
            None => out.push('\\'),
        }
    }
    out
}

fn result(
    tools: &[Tool],
    daemon: &Daemon,
    role: &str,
    method: &str,
    params: &Value,
) -> Option<Value> {
    match method {
        "initialize" => Some(json!({
            "protocolVersion": params.get("protocolVersion").and_then(Value::as_str).unwrap_or("2024-11-05"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "emacs", "version": "1"},
            "instructions": INSTRUCTIONS,
        })),
        "ping" => Some(json!({})),
        "tools/list" => {
            Some(json!({"tools": tools.iter().map(Tool::described).collect::<Vec<_>>()}))
        }
        "tools/call" => {
            let name = params.get("name").and_then(Value::as_str).unwrap_or("");
            let empty = Map::new();
            let given = params
                .get("arguments")
                .and_then(Value::as_object)
                .unwrap_or(&empty);
            let (ok, text) = match tools.iter().find(|t| t.mcp_name() == name) {
                None => (false, format!("no tool {name}")),
                Some(tool) => match tool.words(given, role) {
                    Ok(words) => daemon.call(&words),
                    Err(why) => (false, format!("invalid: {why}")),
                },
            };
            Some(json!({"content": [{"type": "text", "text": text}], "isError": !ok}))
        }
        _ => None,
    }
}

pub fn run(args: &[String]) -> Result<()> {
    if args.first().is_some_and(|a| a == "help") {
        println!(
            "homund mcp [<tools.toml>]: the Emacs tools of tools.toml as an MCP server on stdio"
        );
        return Ok(());
    }
    let path = args.first().map_or("tools.toml", String::as_str);
    let tools = load(Path::new(path))?;
    let role = std::env::var("HOMUN_ROLE")
        .or_else(|_| std::env::var("CLAUDE_ROLE"))
        .unwrap_or_else(|_| "manager".to_string());
    let daemon = Daemon::new();
    let mut out = std::io::stdout().lock();
    for line in std::io::stdin().lock().lines() {
        let Ok(Value::Object(message)) = serde_json::from_str::<Value>(&line?) else {
            continue;
        };
        let Some(id) = message.get("id") else {
            continue;
        };
        let method = message.get("method").and_then(Value::as_str).unwrap_or("");
        let params = message.get("params").cloned().unwrap_or_else(|| json!({}));
        let answer = match result(&tools, &daemon, &role, method, &params) {
            Some(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
            None => {
                json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": format!("no method {method}")}})
            }
        };
        writeln!(out, "{answer}")?;
        out.flush()?;
    }
    Ok(())
}
