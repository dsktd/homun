use std::io::Write;
use std::process::Command;
use std::process::Stdio;
use std::time::Duration;

#[test]
fn test_sigterm_removes_pending_request() {
    let dir = std::env::temp_dir().join(format!("approve-sig-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let mut child = Command::new(env!("CARGO_BIN_EXE_homund"))
        .arg("approve")
        .env("APPROVE_DIR", &dir)
        .env("HOMUN_IS_ROLE", "/dev/null")
        .env_remove("HOMUN_HEADLESS")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(br#"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        .unwrap();
    let requests = dir.join("requests");
    let count = || std::fs::read_dir(&requests).map_or(0, |d| d.count());
    for _ in 0..100 {
        if count() == 1 {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert_eq!(count(), 1, "request never appeared");
    Command::new("kill")
        .args(["-TERM", &child.id().to_string()])
        .status()
        .unwrap();
    assert!(child.wait().unwrap().success());
    assert_eq!(count(), 0, "request file left behind");
    let _ = std::fs::remove_dir_all(&dir);
}
