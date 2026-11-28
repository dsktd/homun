//! `homund roll`: the rolling recreate as a state machine, one role at a time in the launcher's
//! order (the manager first, the mechanic last). Each role goes Staged → Recreating → Healthy, or,
//! when its container does not pass the gate, back to the image it last ran well: RolledBack, or
//! Failed when there is none or that fails too. The roll stops at the first role that is not
//! Healthy; the roles after it keep running as they were.
//!
//! The gate is the container's own podman health check only, passed three polls in a row on the
//! same container. The image record is `lib/roll.nu`'s images.json, read and written in its shape,
//! so the Nu path and this one can take turns. Everything podman is behind `Executor`, so the tests
//! run on a fake one.

use std::path::Path;
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

use anyhow::Result;
use anyhow::anyhow;
use serde::Serialize;
use serde_json::Value;
use serde_json::json;

/// Consecutive passing polls on the same container that make a role healthy.
pub const PASSES: u32 = 3;
/// Keeps a role's previous image from being pruned.
const TAG: &str = "claude:previous-";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub enum Phase {
    Staged,
    Recreating,
    Healthy,
    RolledBack,
    Failed,
}

/// A container as podman reports it; `status` is "missing" when there is none.
#[derive(Clone, Debug, Default)]
pub struct Container {
    pub status: String,
    pub id: String,
    pub image: String,
}

/// What the roll asks of podman and the launcher.
pub trait Executor {
    fn state(
        &mut self,
        name: &str,
    ) -> Container;
    fn healthy(
        &mut self,
        name: &str,
    ) -> bool;
    fn image_exists(
        &mut self,
        image: &str,
    ) -> bool;
    /// Recreate one role's container on `image`.
    fn recreate(
        &mut self,
        role: &str,
        image: &str,
    ) -> Result<()>;
    /// Tag `image` as the role's previous one, or drop the tag.
    fn keep(
        &mut self,
        role: &str,
        image: Option<&str>,
    );
    /// Sleep one poll interval.
    fn wait(&mut self);
}

/// One role's way through the roll.
#[derive(Debug, Serialize)]
pub struct Outcome {
    pub role: String,
    pub phase: Phase,
    pub why: Option<String>,
    pub path: Vec<Phase>,
}

pub struct Roll<'a, E: Executor> {
    pub exec: &'a mut E,
    /// The image record, `{<role>: {current, previous}}`.
    pub record: Value,
    /// Polls of the gate before it gives up.
    pub polls: u32,
    pub rev: String,
    pub now: i64,
}

impl<E: Executor> Roll<'_, E> {
    /// Null when `name` passes the gate, else why not.
    fn gate(
        &mut self,
        name: &str,
    ) -> Option<String> {
        let (mut passes, mut id, mut last) = (0, String::new(), Container::default());
        for poll in 0..self.polls {
            if poll > 0 {
                self.exec.wait();
            }
            last = self.exec.state(name);
            let ok = last.status == "running" && self.exec.healthy(name);
            passes = if !ok {
                0
            } else if last.id == id {
                passes + 1
            } else {
                1
            };
            id.clone_from(&last.id);
            if passes >= PASSES {
                return None;
            }
        }
        Some(if last.status == "running" {
            format!("{name} did not pass the health gate: its health check fails")
        } else {
            format!(
                "{name} did not pass the health gate: the container is {}",
                last.status
            )
        })
    }

    fn try_on(
        &mut self,
        role: &str,
        name: &str,
        image: &str,
    ) -> Option<String> {
        match self.exec.recreate(role, image) {
            Ok(()) => self.gate(name),
            Err(err) => Some(err.to_string()),
        }
    }

    fn entry(
        &self,
        image: &str,
        good: bool,
    ) -> Value {
        json!({"image": image, "rev": self.rev, "time": self.now, "good": good})
    }

    fn put(
        &mut self,
        role: &str,
        mine: Value,
    ) {
        let prev = mine
            .pointer("/previous/image")
            .and_then(Value::as_str)
            .map(str::to_owned);
        self.exec.keep(role, prev.as_deref());
        if !self.record.is_object() {
            self.record = json!({});
        }
        self.record[role] = mine;
    }

    /// Roll one role onto `target`.
    pub fn role(
        &mut self,
        role: &str,
        name: &str,
        target: &str,
    ) -> Outcome {
        let mut path = vec![Phase::Staged];
        let mut mine = self.record.get(role).cloned().unwrap_or_else(|| json!({}));
        // The way back: what ran before, when it had passed the gate, else the older way back
        let back = match mine.get("current") {
            Some(cur) if cur["good"] == true && cur["image"] != target => {
                let mut prev = cur.clone();
                prev.as_object_mut().map(|o| o.remove("good"));
                Some(prev)
            }
            _ => mine.get("previous").cloned(),
        };
        if let Some(back) = &back {
            mine["previous"] = back.clone();
        }
        mine["current"] = self.entry(target, false);
        self.put(role, mine.clone());

        path.push(Phase::Recreating);
        let Some(why) = self.try_on(role, name, target) else {
            mine["current"]["good"] = json!(true);
            self.put(role, mine);
            path.push(Phase::Healthy);
            return Outcome {
                role: role.into(),
                phase: Phase::Healthy,
                why: None,
                path,
            };
        };
        let fail = |path: Vec<Phase>, why: String| Outcome {
            role: role.into(),
            phase: Phase::Failed,
            why: Some(why),
            path: [path, vec![Phase::Failed]].concat(),
        };
        let image = back
            .as_ref()
            .and_then(|b| b["image"].as_str())
            .map(str::to_owned);
        let Some(image) = image.filter(|i| self.exec.image_exists(i)) else {
            return fail(
                path,
                format!("{why}; no previous image of {role} to go back to"),
            );
        };
        if let Some(again) = self.try_on(role, name, &image) {
            mine["previous"]["failed"] = json!(true);
            self.put(role, mine);
            return fail(
                path,
                format!("{why}; the rollback to {image} failed too: {again}"),
            );
        }
        let mut cur = back.unwrap_or_default();
        cur["time"] = json!(self.now);
        cur["good"] = json!(true);
        self.put(role, json!({"current": cur}));
        path.push(Phase::RolledBack);
        Outcome {
            role: role.into(),
            phase: Phase::RolledBack,
            why: Some(why),
            path,
        }
    }

    /// Roll every role in order, stopping after the first that is not Healthy.
    pub fn all(
        &mut self,
        roles: &[(String, String)],
        target: &str,
    ) -> Vec<Outcome> {
        let mut done = Vec::new();
        for (role, name) in roles {
            let out = self.role(role, name, target);
            let stop = out.phase != Phase::Healthy;
            done.push(out);
            if stop {
                break;
            }
        }
        done
    }
}

/// The real executor: podman on PATH, the launcher's `container restart only <role>`.
pub struct Podman {
    pub checkout: PathBuf,
    pub poll: Duration,
}

impl Podman {
    fn podman(args: &[&str]) -> Option<String> {
        let out = Command::new("podman").args(args).output().ok()?;
        out.status
            .success()
            .then(|| String::from_utf8_lossy(&out.stdout).trim().to_owned())
    }

    fn launcher(
        &self,
        args: &[&str],
    ) -> Command {
        let mut cmd = Command::new("nu");
        cmd.arg(self.checkout.join("run.nu")).args(args);
        cmd
    }

    /// The role containers in rolling order, as the launcher lists them.
    pub fn roles(&self) -> Result<Vec<(String, String)>> {
        let out = self.launcher(&["container", "roles"]).output()?;
        if !out.status.success() {
            return Err(anyhow!(
                "cannot list the roles: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        Ok(String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter_map(|l| l.split_once(' '))
            .map(|(r, n)| (r.to_owned(), n.trim().to_owned()))
            .collect())
    }

    /// The image the roll puts the roles on: `claude`'s id.
    pub fn target() -> Option<String> {
        Self::podman(&["image", "inspect", "--format", "{{.Id}}", "claude"])
            .filter(|s| !s.is_empty())
    }
}

impl Executor for Podman {
    fn state(
        &mut self,
        name: &str,
    ) -> Container {
        let Some(out) = Self::podman(&[
            "inspect",
            "--format",
            "{{.State.Status}} {{.Id}} {{.Image}}",
            name,
        ]) else {
            return Container {
                status: "missing".into(),
                ..Container::default()
            };
        };
        let mut w = out.split(' ').map(str::to_owned);
        Container {
            status: w.next().unwrap_or_default(),
            id: w.next().unwrap_or_default(),
            image: w.next().unwrap_or_default(),
        }
    }

    fn healthy(
        &mut self,
        name: &str,
    ) -> bool {
        let Ok(out) = Command::new("podman")
            .args(["healthcheck", "run", name])
            .output()
        else {
            return false;
        };
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        out.status.success() || text.to_lowercase().contains("no defined healthcheck")
    }

    fn image_exists(
        &mut self,
        image: &str,
    ) -> bool {
        Self::podman(&["image", "exists", image]).is_some()
    }

    fn recreate(
        &mut self,
        role: &str,
        image: &str,
    ) -> Result<()> {
        eprintln!("recreating {role} on image {}", short(image));
        let out = self
            .launcher(&["container", "restart", "only", role, "force"])
            .env("HOMUN_IMAGE", image)
            .output()?;
        if out.status.success() {
            return Ok(());
        }
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        let last = text
            .lines()
            .rfind(|l| !l.trim().is_empty())
            .unwrap_or("the restart failed");
        Err(anyhow!("{}", last.chars().take(300).collect::<String>()))
    }

    fn keep(
        &mut self,
        role: &str,
        image: Option<&str>,
    ) {
        let tag = format!("{TAG}{role}");
        let _ = match image {
            Some(image) => Self::podman(&["tag", image, &tag]),
            None => Self::podman(&["untag", &tag]),
        };
    }

    fn wait(&mut self) {
        std::thread::sleep(self.poll);
    }
}

fn short(image: &str) -> &str {
    let id = image.trim_start_matches("sha256:");
    &id[..id.len().min(12)]
}

/// The image record files: the host's own, and the sessions' copy.
pub fn record_files(home: &Path) -> [PathBuf; 2] {
    [
        home.join(".config/claude/images.json"),
        home.join("claude/.services/update/images.json"),
    ]
}

pub fn save(
    record: &Value,
    home: &Path,
) -> Result<()> {
    let text = serde_json::to_string(record)?;
    for file in record_files(home) {
        if let Some(dir) = file.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = file.with_extension("json.tmp");
        std::fs::write(&tmp, &text)?;
        std::fs::rename(&tmp, &file)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::collections::HashSet;

    use super::*;

    /// Containers that come up healthy unless their image is in `sick`.
    #[derive(Default)]
    struct Fake {
        on: HashMap<String, String>,
        sick: HashSet<String>,
        fails: HashSet<String>,
        tags: HashMap<String, String>,
        calls: Vec<String>,
        n: u32,
    }

    fn name(role: &str) -> String {
        format!("claude-{role}")
    }

    impl Executor for Fake {
        fn state(
            &mut self,
            name: &str,
        ) -> Container {
            let role = name.trim_start_matches("claude-");
            match self.on.get(role) {
                Some(image) => Container {
                    status: "running".into(),
                    id: format!("{role}-{}", self.n),
                    image: image.clone(),
                },
                None => Container {
                    status: "missing".into(),
                    ..Container::default()
                },
            }
        }

        fn healthy(
            &mut self,
            name: &str,
        ) -> bool {
            let role = name.trim_start_matches("claude-");
            self.on.get(role).is_some_and(|i| !self.sick.contains(i))
        }

        fn image_exists(
            &mut self,
            image: &str,
        ) -> bool {
            image != "pruned"
        }

        fn recreate(
            &mut self,
            role: &str,
            image: &str,
        ) -> Result<()> {
            self.calls.push(format!("{role} {image}"));
            self.n += 1;
            if self.fails.contains(image) {
                return Err(anyhow!("preflight failed"));
            }
            self.on.insert(role.into(), image.into());
            Ok(())
        }

        fn keep(
            &mut self,
            role: &str,
            image: Option<&str>,
        ) {
            match image {
                Some(i) => self.tags.insert(role.into(), i.into()),
                None => self.tags.remove(role),
            };
        }

        fn wait(&mut self) {}
    }

    fn roles() -> Vec<(String, String)> {
        ["manager", "emacs", "mechanic"]
            .iter()
            .map(|r| (r.to_string(), name(r)))
            .collect()
    }

    fn good(image: &str) -> Value {
        let mut rec = json!({});
        for (role, _) in roles() {
            rec[role] = json!({"current": {"image": image, "rev": "r0", "time": 1, "good": true}});
        }
        rec
    }

    fn roll(
        fake: &mut Fake,
        record: Value,
    ) -> (Vec<Outcome>, Value) {
        let mut roll = Roll {
            exec: fake,
            record,
            polls: 5,
            rev: "r1".into(),
            now: 2,
        };
        let out = roll.all(&roles(), "new");
        (out, roll.record)
    }

    #[test]
    fn healthy_roll_keeps_the_old_image_as_the_way_back() {
        let mut fake = Fake::default();
        let (out, rec) = roll(&mut fake, good("old"));
        assert!(
            out.iter()
                .all(|o| o.path == [Phase::Staged, Phase::Recreating, Phase::Healthy])
        );
        assert_eq!(fake.calls, ["manager new", "emacs new", "mechanic new"]);
        assert_eq!(rec["manager"]["current"]["image"], "new");
        assert_eq!(rec["manager"]["current"]["good"], true);
        assert_eq!(rec["manager"]["previous"]["image"], "old");
        assert_eq!(fake.tags["manager"], "old");
    }

    #[test]
    fn injected_failure_rolls_back_and_stops_the_roll() {
        let mut fake = Fake {
            sick: ["new".to_string()].into(),
            ..Fake::default()
        };
        let (out, rec) = roll(&mut fake, good("old"));
        assert_eq!(
            out.len(),
            1,
            "the roll goes on past a failed manager: {out:?}"
        );
        assert_eq!(
            out[0].path,
            [Phase::Staged, Phase::Recreating, Phase::RolledBack]
        );
        assert!(
            out[0]
                .why
                .as_deref()
                .unwrap()
                .contains("health check fails")
        );
        assert_eq!(fake.calls, ["manager new", "manager old"]);
        assert_eq!(rec["manager"]["current"]["image"], "old");
        assert_eq!(rec["manager"]["current"]["good"], true);
        assert_eq!(
            rec["emacs"]["current"]["image"], "old",
            "a role after the failed one was touched"
        );
    }

    #[test]
    fn failed_recreate_rolls_back_too() {
        let mut fake = Fake {
            fails: ["new".to_string()].into(),
            ..Fake::default()
        };
        let (out, _) = roll(&mut fake, good("old"));
        assert_eq!(out[0].phase, Phase::RolledBack);
        assert!(out[0].why.as_deref().unwrap().contains("preflight failed"));
    }

    #[test]
    fn no_way_back_fails() {
        let mut fake = Fake {
            sick: ["new".to_string()].into(),
            ..Fake::default()
        };
        let (out, rec) = roll(&mut fake, json!({}));
        assert_eq!(
            out[0].path,
            [Phase::Staged, Phase::Recreating, Phase::Failed]
        );
        assert_eq!(fake.calls, ["manager new"]);
        assert_eq!(rec["manager"]["current"]["good"], false);
        let mut fake = Fake {
            sick: ["new".to_string()].into(),
            ..Fake::default()
        };
        let mut rec = good("x");
        rec["manager"] =
            json!({"current": {"image": "new", "good": false}, "previous": {"image": "pruned"}});
        assert_eq!(roll(&mut fake, rec).0[0].phase, Phase::Failed);
    }

    #[test]
    fn failed_rollback_marks_the_previous_image() {
        let mut fake = Fake {
            sick: ["new".to_string(), "old".to_string()].into(),
            ..Fake::default()
        };
        let (out, rec) = roll(&mut fake, good("old"));
        assert_eq!(out[0].phase, Phase::Failed);
        assert_eq!(rec["manager"]["previous"]["failed"], true);
    }

    #[test]
    fn an_unproven_image_is_not_a_way_back() {
        let mut fake = Fake::default();
        let mut rec = good("old");
        rec["manager"] = json!({"current": {"image": "bad", "good": false}, "previous": {"image": "old", "rev": "r0", "time": 1}});
        let (_, rec) = roll(&mut fake, rec);
        assert_eq!(rec["manager"]["previous"]["image"], "old");
    }
}
