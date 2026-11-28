//! `homund presence beat <focused true|false> <idle_s> | show`: where Cal is. The desktop
//! writes its heartbeat `attn/presence/desk.json` {device,focused,idle_s,ts} (what
//! `claude-attn.el` wrote itself); `show` prints the best presence: `desk` when that heartbeat is
//! fresh and its idle time under 300 s, else `mobile` when the gateway saw a paired device
//! (`devices/*/seen`, its mtime) in the last 90 s, else `away`.

use std::fs;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::SystemTime;
use std::time::UNIX_EPOCH;

use serde_json::Value;
use serde_json::json;

const DESK_IDLE: i64 = 300;
const BEAT_FRESH: i64 = 90;
const PHONE_SEEN: i64 = 90;

const DOC: &str = "homund presence beat <focused true|false> <idle_s>\n\
                   \x20   write the desktop heartbeat\n\
                   homund presence show\n\
                   \x20   print desk, mobile or away\n\
ATTN_DIR and DEVICES_DIR override the paths (tests).\n";

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

fn dirs() -> (PathBuf, PathBuf) {
    let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
    let var = |key: &str, fallback: &str| {
        std::env::var_os(key)
            .filter(|v| !v.is_empty())
            .map_or_else(|| home.join(fallback), PathBuf::from)
    };
    (
        var("ATTN_DIR", "claude/.services/attn"),
        var("DEVICES_DIR", "claude/.services/cockpit-gateway/devices"),
    )
}

pub fn beat(
    attn: &std::path::Path,
    focused: bool,
    idle: i64,
    ts: i64,
) -> std::io::Result<()> {
    let dir = attn.join("presence");
    fs::create_dir_all(&dir)?;
    let tmp = dir.join(format!("desk.json.{}", std::process::id()));
    let row = json!({"device": "desk", "ts": ts, "focused": focused, "idle_s": idle});
    fs::write(&tmp, row.to_string())?;
    fs::rename(tmp, dir.join("desk.json"))
}

pub fn show(
    attn: &std::path::Path,
    devices: &std::path::Path,
    at: i64,
) -> &'static str {
    let desk = fs::read_to_string(attn.join("presence/desk.json"))
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .is_some_and(|v| {
            at - v["ts"].as_i64().unwrap_or(0) < BEAT_FRESH
                && v["idle_s"].as_i64().unwrap_or(i64::MAX) < DESK_IDLE
        });
    if desk {
        return "desk";
    }
    let phone = fs::read_dir(devices).is_ok_and(|d| {
        d.flatten().any(|e| {
            fs::metadata(e.path().join("seen"))
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .is_some_and(|t| at - (t.as_secs() as i64) < PHONE_SEEN)
        })
    });
    if phone { "mobile" } else { "away" }
}

pub fn run(args: &[String]) -> ExitCode {
    let (attn, devices) = dirs();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    match args[..] {
        ["help" | "--help"] => {
            print!("{DOC}");
            ExitCode::SUCCESS
        }
        ["show"] => {
            println!("{}", show(&attn, &devices, now()));
            ExitCode::SUCCESS
        }
        ["beat", focused @ ("true" | "false"), idle] if idle.parse::<i64>().is_ok() => {
            match beat(&attn, focused == "true", idle.parse().unwrap_or(0), now()) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => {
                    eprintln!("homund presence: {e}");
                    ExitCode::FAILURE
                }
            }
        }
        _ => {
            eprint!("{DOC}");
            ExitCode::from(2)
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("homund-presence-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn test_desk_then_mobile_then_away() {
        let (attn, dev) = (tmp("a"), tmp("d"));
        assert_eq!(show(&attn, &dev, 1000), "away");
        beat(&attn, true, 10, 1000).unwrap();
        assert_eq!(show(&attn, &dev, 1050), "desk");
        assert_eq!(show(&attn, &dev, 1100), "away");
        beat(&attn, false, 400, 1000).unwrap();
        assert_eq!(show(&attn, &dev, 1010), "away");
        fs::create_dir_all(dev.join("phone")).unwrap();
        fs::write(dev.join("phone/seen"), "").unwrap();
        assert_eq!(show(&attn, &dev, now()), "mobile");
        assert_eq!(show(&attn, &dev, now() + 500), "away");
    }
}
