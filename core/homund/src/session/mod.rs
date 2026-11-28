//! `homund session`: how a role's claude runs, started, compacted, rotated and recycled, for both
//! kinds of session. It replaces four scripts of `container/`, one verb each, with the same files,
//! markers and environment, so a role switches between them by `session.impl` alone:
//!
//! - `broker <dir> [claude args]`: a headless `claude -p` on stream-json (container/session-broker)
//! - `relay <cmd> [args]`: an interactive claude on a pty that types `/compact` when the user's
//!   Emacs asks (container/compact-relay)
//! - `rotate plan|start ...`: a fresh session seeded from an outgrown transcript
//!   (container/session-rotate)
//! - `recycle <role> [idle [min]]`: end an idle side role's claude so it starts fresh
//!   (container/role-recycle)

pub mod broker;
pub mod recycle;
pub mod relay;
pub mod rotate;

use std::fs;
use std::io::Read;
use std::path::Path;
use std::process::ExitCode;

pub const HELP: &str = "\
homund session <verb>: start, compact, rotate and recycle a role's session
  broker <dir> [claude args...]   a headless claude -p on stream-json, restarted on exit
  relay <cmd> [args...]           an interactive claude on a pty, /compact typed for Emacs
  rotate plan [<session>] [transcript <file>] [threshold <mb>] [turns <n>] [show]
  rotate start <session>          seed and pin a new session when the transcript outgrew
  recycle <role> [idle [min]]     end an idle side role's claude so its next start is fresh
  help                            this text";

pub fn run(args: &[String]) -> ExitCode {
    let rest = args.get(1..).unwrap_or_default();
    match args.first().map(String::as_str) {
        Some("broker") => broker::main(rest),
        Some("relay") => relay::main(rest),
        Some("rotate") => rotate::main(rest),
        Some("recycle") => recycle::main(rest),
        Some("help") => {
            println!("{HELP}");
            ExitCode::SUCCESS
        }
        _ => {
            eprintln!("{HELP}");
            ExitCode::from(2)
        }
    }
}

/// Replace `path` through `<path>.tmp` in the same directory.
pub fn write_atomic(
    path: &Path,
    text: &str,
) -> std::io::Result<()> {
    let mut name = path.file_name().unwrap_or_default().to_owned();
    name.push(".tmp");
    let temp = path.with_file_name(name);
    fs::write(&temp, text)?;
    fs::rename(&temp, path)
}

/// A random (version 4) UUID, as Python's uuid4 prints it.
pub fn uuid4() -> String {
    let mut b = [0u8; 16];
    if fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut b))
        .is_err()
    {
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
            ^ u128::from(std::process::id()) << 64;
        b = t.to_le_bytes();
    }
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h: String = b.iter().map(|x| format!("{x:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &h[..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..]
    )
}

pub fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}

pub fn home() -> std::path::PathBuf {
    std::env::var_os("HOME").unwrap_or_default().into()
}

/// The first `n` characters of `s`.
pub fn cut(
    s: &str,
    n: usize,
) -> &str {
    s.char_indices().nth(n).map_or(s, |(i, _)| &s[..i])
}
