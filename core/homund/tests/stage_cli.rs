use std::io::BufRead;
use std::io::Write;
use std::process::Command;
use std::process::Stdio;

fn stage(
    dir: &std::path::Path,
    args: &[&str],
    stdin: &str,
) -> (bool, String) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_homund"))
        .arg("stage")
        .args(args)
        .env("HOMUN_STAGE", dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(stdin.as_bytes())
        .unwrap();
    let out = child.wait_with_output().unwrap();
    (out.status.success(), String::from_utf8(out.stdout).unwrap())
}

#[test]
fn test_subscribe_sees_changes_of_another_process_and_list_survives() {
    let dir = std::env::temp_dir().join(format!("stage-cli-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let root = r#"{"type":"text","id":"t","text":"a"}"#;
    assert!(stage(&dir, &["store", "manager", "roll", "Roll", "turn"], root).0);
    let mut sub = Command::new(env!("CARGO_BIN_EXE_homund"))
        .args(["stage", "subscribe"])
        .env("HOMUN_STAGE", &dir)
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut lines = std::io::BufReader::new(sub.stdout.take().unwrap()).lines();
    // the open scene first, then the change made by a second process
    assert!(
        lines
            .next()
            .unwrap()
            .unwrap()
            .contains(r#""topic":"stage/roll""#)
    );
    let (ok, out) = stage(
        &dir,
        &["patch", "manager", "roll"],
        r#"[{"path":"/t/text","set":"b"}]"#,
    );
    assert!(ok, "{out}");
    let line = lines.next().unwrap().unwrap();
    assert!(
        line.contains(r#""kind":"stage""#) && line.contains(r#""op":"patch""#),
        "{line}"
    );
    let _ = sub.kill();
    // a refusal is {error, field} with exit 1, and changes nothing
    let (ok, out) = stage(
        &dir,
        &["patch", "manager", "roll"],
        r#"[{"path":"/zz/a","set":1}]"#,
    );
    assert!(!ok && out.contains(r#""error":"no such node""#), "{out}");
    let (_, listed) = stage(&dir, &["list"], "");
    assert!(
        listed.contains(r#""version":2"#) && listed.contains(r#""text":"b""#),
        "{listed}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
