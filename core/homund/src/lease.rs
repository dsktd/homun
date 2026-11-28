//! `homund lease take <holder> <scope> [wait <s>] | release <holder> | show`: the repair lease
//! (`~/claude/.services/mechanic/lease`), what `bin/homun-lease` did, with the same output and
//! exit codes. The file is created by hard-linking a private temp file, so of any number of
//! racing takers exactly one wins, and it is removed only by its holder (or once void).

use std::fs;
use std::io::Write;
use std::path::Path;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;
use std::time::SystemTime;
use std::time::UNIX_EPOCH;

use serde_json::Value;
use serde_json::json;

/// A lease older than this is void once its holder's heartbeat is stale.
const MAX_AGE: i64 = 7200;
/// Heartbeat age (seconds) under which a holder counts as alive.
const FRESH: i64 = 600;

const DOC: &str = include_str!("lease_help.txt");

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

pub struct Lease {
    pub path: PathBuf,
    /// Where the manager's heartbeat lives (`MANAGER_DIR`).
    pub manager: PathBuf,
}

impl Lease {
    pub fn from_env() -> Self {
        let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
        let path = std::env::var_os("LEASE_FILE")
            .filter(|v| !v.is_empty())
            .map_or_else(
                || home.join("claude/.services/mechanic/lease"),
                PathBuf::from,
            );
        let manager = std::env::var_os("MANAGER_DIR")
            .filter(|v| !v.is_empty())
            .map_or_else(
                || {
                    path.parent()
                        .and_then(Path::parent)
                        .unwrap_or(Path::new("."))
                        .join("manager")
                },
                PathBuf::from,
            );
        Self { path, manager }
    }

    /// The lease as written; an unreadable file reads as a holder `?` so nobody takes it by mistake.
    pub fn read(&self) -> Option<Value> {
        match fs::read_to_string(&self.path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(_) => Some(json!({"holder": "?", "since": 0, "scope": "unreadable"})),
            Ok(text) => match serde_json::from_str::<Value>(&text) {
                Ok(v) if v.is_object() => Some(v),
                Ok(_) => Some(json!({"holder": "?", "since": 0})),
                Err(_) => Some(json!({"holder": "?", "since": 0, "scope": "unreadable"})),
            },
        }
    }

    fn alive(
        &self,
        holder: &str,
    ) -> bool {
        let dir = self.path.parent().unwrap_or(Path::new("."));
        let beat = match holder {
            "manager" => self.manager.join("heartbeat"),
            "mechanic" => dir.join("heartbeat"),
            _ => dir.join(format!("heartbeat-{holder}")),
        };
        fs::metadata(beat)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .is_some_and(|t| now() - (t.as_secs() as i64) < FRESH)
    }

    fn void(
        &self,
        lease: &Value,
    ) -> bool {
        let since = lease["since"].as_f64().unwrap_or(0.0) as i64;
        now() - since > MAX_AGE && !self.alive(lease["holder"].as_str().unwrap_or("?"))
    }

    /// Remove the file if it is still the lease we looked at.
    fn drop_if(
        &self,
        seen: &Value,
    ) {
        if self.read().as_ref() == Some(seen) {
            let _ = fs::remove_file(&self.path);
        }
    }

    /// Create the lease unless another live holder has it; return the blocking lease, or None.
    pub fn try_take(
        &self,
        holder: &str,
        scope: &str,
    ) -> Option<Value> {
        let dir = self.path.parent().unwrap_or(Path::new("."));
        let _ = fs::create_dir_all(dir);
        let tmp = dir.join(format!(
            ".{}.{}.{:?}",
            self.path.file_name()?.to_string_lossy(),
            std::process::id(),
            std::thread::current().id()
        ));
        let text = json!({"holder": holder, "since": now(), "scope": scope}).to_string();
        let written = fs::File::create_new(&tmp).and_then(|mut f| f.write_all(text.as_bytes()));
        if written.is_err() {
            let _ = fs::remove_file(&tmp);
            return self.read();
        }
        let out = self.link(&tmp, holder);
        let _ = fs::remove_file(&tmp);
        out
    }

    fn link(
        &self,
        tmp: &Path,
        holder: &str,
    ) -> Option<Value> {
        for _ in 0..3 {
            match fs::hard_link(tmp, &self.path) {
                Ok(()) => return None,
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(_) => return self.read(),
            }
            let Some(held) = self.read() else { continue };
            if held["holder"] == holder {
                return fs::rename(tmp, &self.path).err().and(Some(held));
            }
            if !self.void(&held) {
                return Some(held);
            }
            self.drop_if(&held);
        }
        self.read()
    }

    /// Delete the lease if it names `holder`; return the lease that blocks the release.
    pub fn release(
        &self,
        holder: &str,
    ) -> Option<Value> {
        let held = self.read()?;
        if held["holder"] != holder {
            return Some(held);
        }
        self.drop_if(&held);
        None
    }
}

fn age(lease: &Value) -> i64 {
    now() - lease["since"].as_f64().unwrap_or(0.0) as i64
}

fn describe(held: &Value) -> (String, String) {
    let text = |k: &str| match &held[k] {
        Value::String(s) => s.clone(),
        Value::Null => "None".into(),
        other => other.to_string(),
    };
    (text("holder"), text("scope"))
}

/// The role keys of `roles/roles.toml` (`HOMUN_ROLES` names the file; the shim sets it).
fn role_keys() -> Vec<String> {
    let file = std::env::var_os("HOMUN_ROLES").map(PathBuf::from);
    file.and_then(|f| fs::read_to_string(f).ok())
        .and_then(|t| t.parse::<toml::Table>().ok())
        .map_or_else(Vec::new, |t| t.keys().cloned().collect())
}

pub fn run(args: &[String]) -> ExitCode {
    let lease = Lease::from_env();
    let a: Vec<&str> = args.iter().map(String::as_str).collect();
    match a.as_slice() {
        ["take", holder, scope] => take(&lease, holder, scope, 0.0),
        ["take", holder, scope, "wait", secs] => match secs.parse::<f64>() {
            Ok(s) => take(&lease, holder, scope, s),
            Err(_) => usage(2),
        },
        ["release", holder] => match lease.release(holder) {
            None => ExitCode::SUCCESS,
            Some(held) => {
                let (h, s) = describe(&held);
                eprintln!("not released: held by {h}: {s}");
                ExitCode::from(1)
            }
        },
        ["show"] => match lease.read() {
            None => {
                println!("free");
                ExitCode::from(1)
            }
            Some(mut held) => {
                held["age"] = json!(age(&held));
                println!("{held}");
                ExitCode::SUCCESS
            }
        },
        ["help"] => usage(0),
        _ => usage(2),
    }
}

fn usage(code: u8) -> ExitCode {
    println!("{DOC}");
    ExitCode::from(code)
}

fn take(
    lease: &Lease,
    holder: &str,
    scope: &str,
    wait: f64,
) -> ExitCode {
    if !role_keys().iter().any(|k| k == holder) {
        eprintln!("holder must be a role key from roles.toml, not '{holder}'");
        return ExitCode::from(2);
    }
    let deadline = std::time::Instant::now() + Duration::from_secs_f64(wait.max(0.0));
    loop {
        let Some(held) = lease.try_take(holder, scope) else {
            return ExitCode::SUCCESS;
        };
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        if left.is_zero() {
            let (h, s) = describe(&held);
            eprintln!("held by {h} for {}s: {s}", age(&held));
            return ExitCode::from(1);
        }
        std::thread::sleep(
            left.min(Duration::from_secs(2))
                .max(Duration::from_millis(50)),
        );
    }
}

#[cfg(test)]
mod test {
    use std::sync::Arc;
    use std::sync::Barrier;

    use super::*;

    fn lease(name: &str) -> Lease {
        let dir = std::env::temp_dir().join(format!("homund-lease-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        Lease {
            path: dir.join("lease"),
            manager: dir.join("manager"),
        }
    }

    #[test]
    fn test_race_has_one_winner() {
        for round in 0..20 {
            let lease = Arc::new(lease(&format!("race{round}")));
            let gate = Arc::new(Barrier::new(8));
            let wins: Vec<bool> = (0..8)
                .map(|i| {
                    let (lease, gate) = (lease.clone(), gate.clone());
                    std::thread::spawn(move || {
                        gate.wait();
                        lease.try_take(&format!("r{i}"), "x").is_none()
                    })
                })
                .collect::<Vec<_>>()
                .into_iter()
                .map(|h| h.join().unwrap())
                .collect();
            assert_eq!(wins.iter().filter(|w| **w).count(), 1, "round {round}");
            let holder = lease.read().unwrap()["holder"].as_str().unwrap().to_owned();
            assert!(wins[holder[1..].parse::<usize>().unwrap()]);
        }
    }

    #[test]
    fn test_same_holder_refreshes_and_other_release_refused() {
        let lease = lease("own");
        assert!(lease.try_take("manager", "a").is_none());
        assert!(lease.try_take("manager", "b").is_none());
        assert_eq!(lease.read().unwrap()["scope"], "b");
        assert!(lease.release("mechanic").is_some());
        assert!(lease.release("manager").is_none());
        assert!(lease.read().is_none());
    }

    #[test]
    fn test_old_lease_is_void_only_without_heartbeat() {
        let lease = lease("void");
        let old = json!({"holder": "mechanic", "since": now() - MAX_AGE - 5, "scope": "x"});
        fs::write(&lease.path, old.to_string()).unwrap();
        fs::write(lease.path.with_file_name("heartbeat"), "").unwrap();
        assert!(lease.try_take("manager", "y").is_some());
        fs::remove_file(lease.path.with_file_name("heartbeat")).unwrap();
        assert!(lease.try_take("manager", "y").is_none());
    }
}
