//! `homund msg send <to> <alarm> <msg> | tail <to> [n]`: the bus door that replaces the shell
//! homun-msg, byte for byte: the same line, stderr and exit codes. Lengths count bytes, as the
//! shell does in the containers' C locale.

use std::ffi::OsString;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::ExitCode;

use crate::envelope::Legacy;
use crate::journal::Journal;

fn usage() -> ExitCode {
    eprintln!("usage: homun-msg send <to> <alarm> <msg> | tail <to>");
    ExitCode::from(2)
}

fn name_ok(name: &str) -> bool {
    !name.is_empty()
        && name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
}

fn env(key: &str) -> Option<String> {
    std::env::var_os(key)
        .map(|value| value.to_string_lossy().into_owned())
        .filter(|value| !value.is_empty())
}

/// The message as `tr -c '[:print:]' ' ' | cut -c1-500` left it: printable ASCII, 500 bytes.
fn clamp(msg: &[u8]) -> String {
    msg.iter()
        .take(500)
        .map(|b| {
            if (0x20..0x7f).contains(b) {
                *b as char
            } else {
                ' '
            }
        })
        .collect()
}

pub fn run(args: Vec<OsString>) -> ExitCode {
    if args.len() < 2 {
        return usage();
    }
    let to = args[1].to_string_lossy().into_owned();
    if !name_ok(&to) {
        return usage();
    }
    let bus = env("HOMUN_BUS").map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join("claude/.services/bus")
    });
    let dir = bus.join(&to);
    match args[0].as_bytes() {
        b"tail" => {
            let n = args
                .get(2)
                .filter(|n| !n.is_empty())
                .cloned()
                .unwrap_or("20".into());
            let err = std::process::Command::new("tail")
                .arg("-n")
                .arg(n)
                .arg(dir.join("inbox.jsonl"))
                .exec();
            eprintln!("homun-msg: {err}");
            return ExitCode::from(127);
        }
        b"send" if args.len() == 4 => {}
        _ => return usage(),
    }
    let alarm = args[2].to_string_lossy().into_owned();
    if alarm.is_empty() || alarm.len() > 64 {
        return usage();
    }
    if std::fs::create_dir_all(&dir).is_err() {
        eprintln!("homun-msg: cannot create {}", dir.display());
        return ExitCode::SUCCESS;
    }
    let id = std::fs::read_to_string("/proc/sys/kernel/random/uuid")
        .map(|id| id.trim().to_string())
        .unwrap_or_else(|_| format!("{}", chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)));
    let line = Legacy {
        id,
        ts: Some(chrono::Utc::now().timestamp().to_string()),
        from: Some(
            env("HOMUN_ROLE")
                .or(env("CLAUDE_ROLE"))
                .unwrap_or("host".into()),
        ),
        to: Some(to.clone()),
        alarm,
        msg: clamp(args[3].as_bytes()),
        via: env("HOMUN_VIA").filter(|via| name_ok(via)),
    }
    .line();
    if line.len() >= 4000 {
        eprintln!("homun-msg: message over 4 KiB, dropped");
        return ExitCode::SUCCESS;
    }
    if Journal::inbox(dir).append(&line).is_err() {
        eprintln!("homun-msg: could not deliver to {to}");
    }

    ExitCode::SUCCESS
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_clamp() {
        assert!(clamp(b"a\tb\n\x7f\xc3\xa9") == "a b    ");
        assert!(clamp(&[b'y'; 900]).len() == 500);
    }
}
