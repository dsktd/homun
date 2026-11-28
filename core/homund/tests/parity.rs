//! `homund plan` against `run.nu container plan` for every role in roles.toml, offline, on two
//! fixture homes: a bare one, and one with host config, markers, local roles, other roles' state
//! and ad-hoc mounts and ports state (which must not reach the plan).

use std::path::Path;
use std::path::PathBuf;
use std::process::Command;

use serde_json::Value;

fn checkout() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").canonicalize().unwrap()
}

fn fixture(name: &str) -> PathBuf {
    let home = std::env::temp_dir().join(format!("homund-parity-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(home.join("run")).unwrap();
    home
}

fn write(
    home: &Path,
    file: &str,
    text: &str,
) {
    let path = home.join(file);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn rich(home: &Path) {
    let cockpit = home.join("doom");
    std::fs::create_dir_all(&cockpit).unwrap();
    let config = serde_json::json!({
        "roles": ["auditor"],
        "kvm": true,
        "cockpit": { "config": cockpit },
    });
    write(home, ".config/claude/config.json", &config.to_string());
    write(home, ".config/claude/agent.json", "{}");
    write(home, ".config/homun/homun.toml", "gpu = true\n");
    write(home, ".config/claude/mechanic", "");
    write(home, ".config/claude/cpuset", "0-3\n");
    write(home, ".config/homun/roles/reviewer.json", r#"{"container": true, "access": {"gh": true}}"#);
    write(home, ".config/homun/roles/mechanic.json", r#"{"access": {"secrets": "ro"}}"#);
    std::fs::create_dir_all(home.join(".local/share/claude/claude")).unwrap();
    std::fs::create_dir_all(home.join(".local/share/claude/mechanic/claude")).unwrap();
}

fn command(
    home: &Path,
    program: impl AsRef<std::ffi::OsStr>,
) -> Command {
    let mut command = Command::new(program);
    command
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap())
        .env("HOME", home)
        .env("XDG_RUNTIME_DIR", home.join("run"))
        .env("DBUS_SESSION_BUS_ADDRESS", "unix:path=/nonexistent")
        .current_dir(checkout());
    command
}

fn output(command: &mut Command) -> Option<String> {
    let out = command.output().unwrap();
    out.status.success().then(|| String::from_utf8(out.stdout).unwrap())
}

/// The spec in the line format of `homun container plan`.
fn text(
    key: &str,
    plan: &Value,
) -> String {
    let spec = &plan["spec"];
    let lines = |v: &Value| -> Vec<String> {
        v.as_array().unwrap().iter().map(|s| s.as_str().unwrap().to_string()).collect()
    };
    let prep = &spec["prep"];
    let mut out = vec![
        format!("# homun container plan {key}"),
        format!("name {}", spec["name"].as_str().unwrap()),
        format!("role {}", spec["role"].as_str().unwrap()),
        format!("hash {}", plan["hash"].as_str().unwrap()),
        "[args]".into(),
    ];
    out.extend(lines(&spec["args"]));
    out.push("[cmd]".into());
    out.extend(lines(&spec["cmd"]));
    out.push("[health]".into());
    out.extend(lines(&spec["health"]));
    out.push("[prep]".into());
    out.extend(lines(&prep["mkdirs"]).into_iter().map(|d| format!("mkdir {d}")));
    out.extend(lines(&prep["touches"]).into_iter().map(|f| format!("touch {f}")));
    if let Some(seed) = prep["seed"].as_object() {
        out.push(format!("seed {} -> {}", seed["src"].as_str().unwrap(), seed["dst"].as_str().unwrap()));
    }
    out.join("\n")
}

fn parity(home: &Path) {
    let toml = std::fs::read_to_string(checkout().join("roles/roles.toml")).unwrap();
    let roles: toml::Table = toml::from_str(&toml).unwrap();
    let keys = roles.keys().cloned().chain(["editor".into(), "reviewer".into()]);
    let mut planned = 0;
    for key in keys {
        let nu = output(command(home, "nu").args(["run.nu", "container", "plan", &key]));
        let rust = output(command(home, env!("CARGO_BIN_EXE_homund")).args(["plan", &key, "."]));
        let rust = rust.map(|out| text(&key, &serde_json::from_str(&out).unwrap()));
        assert_eq!(nu.as_deref().map(str::trim_end), rust.as_deref(), "plan of {key}");
        planned += usize::from(rust.is_some());
    }
    assert!(planned >= 3, "only {planned} roles planned");
}

#[test]
fn test_parity_bare() {
    parity(&fixture("bare"));
}

#[test]
fn test_parity_rich() {
    let home = fixture("rich");
    rich(&home);
    parity(&home);
}
