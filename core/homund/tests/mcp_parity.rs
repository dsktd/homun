//! `homund mcp` against `emacs.py`: the same tool list, the same answer to a call of every tool
//! (through a fake emacsclient that answers with the words it got), the golden list, and invalid
//! calls that name the field.

use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::path::PathBuf;
use std::process::Command;
use std::process::Stdio;

use serde_json::Value;
use serde_json::json;

fn checkout() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap()
}

fn plugin() -> PathBuf {
    checkout().join("container/channels/homun")
}

fn golden() -> Vec<Value> {
    let text = std::fs::read_to_string(checkout().join("tests/golden/emacs-tools.json")).unwrap();
    serde_json::from_str(&text).unwrap()
}

/// A HOME with a socket file and an emacsclient that answers `ok` and the words it got.
fn home() -> (PathBuf, PathBuf) {
    static N: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let n = N.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let home = std::env::temp_dir().join(format!("homund-mcp-{}-{n}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(home.join("claude/.services/emacs")).unwrap();
    std::fs::write(home.join("claude/.services/emacs/socket"), "").unwrap();
    std::fs::create_dir_all(home.join("bin")).unwrap();
    let fake = home.join("bin/emacsclient");
    let schema = serde_json::to_string(&golden()).unwrap();
    std::fs::write(home.join("schema.json"), schema).unwrap();
    let script = format!(
        "#!/bin/sh\nshift 4\nif [ \"$*\" = \"api schema\" ]; then\n  printf '\"ok\\\\n'; sed 's/\\\\/\\\\\\\\/g; s/\"/\\\\\"/g' {}; printf '\"'\nelse\n  printf '\"ok\\\\n%s\"' \"$*\"\nfi\n",
        home.join("schema.json").display()
    );
    std::fs::write(&fake, script).unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    (home.clone(), home.join("bin"))
}

fn serve(
    mut cmd: Command,
    lines: &[Value],
) -> Vec<Value> {
    let (home, bin) = home();
    let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap());
    let mut child = cmd
        .env("HOME", &home)
        .env("PATH", path)
        .env("HOMUN_EVAL_WRAPPER", "/nonexistent")
        .env("HOMUN_ROLE", "manager")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    for line in lines {
        writeln!(stdin, "{line}").unwrap();
    }
    drop(stdin);
    let out = child.wait_with_output().unwrap();
    String::from_utf8(out.stdout)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

fn homund() -> Command {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_homund"));
    cmd.arg("mcp").arg(plugin().join("tools.toml"));
    cmd
}

fn python() -> Command {
    let mut cmd = Command::new("python3");
    cmd.arg("-I").arg(plugin().join("servers/emacs.py"));
    cmd
}

/// A valid value for each argument type.
fn sample(arg: &Value) -> Value {
    match arg["type"].as_str().unwrap() {
        "int" => json!(3),
        "bool" => json!(true),
        "enum" => arg["choices"][0].clone(),
        "symbol" => json!("some-name"),
        "json" => json!({}),
        _ => json!("text -x"),
    }
}

fn calls(tools: &[Value]) -> Vec<Value> {
    let mut lines = vec![json!({"jsonrpc": "2.0", "id": 0, "method": "tools/list"})];
    for (i, tool) in tools.iter().enumerate() {
        let args: serde_json::Map<String, Value> = tool["args"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|a| a["required"] == true)
            .map(|a| (a["key"].as_str().unwrap().to_string(), sample(a)))
            .collect();
        let name = tool["name"].as_str().unwrap().replace(' ', "_");
        lines.push(json!({"jsonrpc": "2.0", "id": i + 1, "method": "tools/call", "params": {"name": name, "arguments": args}}));
    }
    lines
}

#[test]
fn both_servers_agree_on_every_tool() {
    let tools = golden();
    let lines = calls(&tools);
    let rust = serve(homund(), &lines);
    let python = serve(python(), &lines);
    assert_eq!(rust.len(), tools.len() + 1);
    assert_eq!(rust[0], python[0], "tools/list differs");
    for (i, tool) in tools.iter().enumerate() {
        assert_eq!(
            rust[i + 1],
            python[i + 1],
            "call of {} differs",
            tool["name"]
        );
        assert_eq!(
            rust[i + 1]["result"]["isError"],
            false,
            "{} failed",
            tool["name"]
        );
    }
}

#[test]
fn registry_is_the_golden_list() {
    let listed = serve(
        homund(),
        &[json!({"jsonrpc": "2.0", "id": 0, "method": "tools/list"})],
    );
    let tools = listed[0]["result"]["tools"].as_array().unwrap().clone();
    let golden = golden();
    assert_eq!(tools.len(), golden.len());
    for (tool, entry) in tools.iter().zip(&golden) {
        assert_eq!(
            tool["name"],
            entry["name"].as_str().unwrap().replace(' ', "_")
        );
        assert_eq!(tool["description"], entry["doc"]);
        let required: Vec<&str> = entry["args"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|a| a["required"] == true)
            .map(|a| a["key"].as_str().unwrap())
            .collect();
        let got: Vec<&str> = tool["inputSchema"]["required"]
            .as_array()
            .map(|r| r.iter().map(|v| v.as_str().unwrap()).collect())
            .unwrap_or_default();
        assert_eq!(got, required, "{}", entry["name"]);
    }
}

fn failure(
    name: &str,
    args: Value,
) -> String {
    let line = json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": args}});
    let answer = serve(homund(), &[line]);
    assert_eq!(answer[0]["result"]["isError"], true);
    answer[0]["result"]["content"][0]["text"]
        .as_str()
        .unwrap()
        .to_string()
}

#[test]
fn invalid_calls_name_the_field() {
    assert!(failure("stage_patch", json!({"id": "a"})).contains("ops: required"));
    assert!(
        failure(
            "stage_patch",
            json!({"id": "a", "ops": [], "if_version": "x"})
        )
        .contains("if_version:")
    );
    assert!(failure("mode_set", json!({"mode": "Bad Mode", "state": "on"})).contains("mode:"));
    assert!(failure("mode_set", json!({"mode": "ok", "state": "maybe"})).contains("state:"));
    assert!(failure("mode_set", json!({"mode": "ok", "state": "on", "nope": 1})).contains("nope:"));
}
