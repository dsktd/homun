//! `homund stage ...`: the Stage's scene store. One record per open scene in
//! `<stage dir>/<id>.json` (closed ones in `closed/`), every change announced as a bus envelope
//! (`kind: stage`, `topic: stage/<id>`, body `{op, id, version}`) on `<stage dir>/events.jsonl`.
//! Readers follow `subscribe`; the Elisp store keeps a mirror and falls back to its own files.
//!
//! Patch paths are by node id as in the Elisp store: `/<node>`, `/<node>/<field>`,
//! `/<node>/<list>/<item-id>` and `/<node>/<list>/<item-id>/<field>`; an item id of `-`
//! appends. Only the owner (or the role `cal`) changes a scene. Node types are not validated
//! here: the Elisp side checks them before it commits.

use std::io::Read;
use std::io::Write;
use std::path::Path;
use std::path::PathBuf;
use std::process::ExitCode;

use anyhow::Result;
use anyhow::bail;
use serde_json::Value;
use serde_json::json;

use crate::envelope::Envelope;
use crate::envelope::Kind;
use crate::journal::Journal;

const MAX_BYTES: usize = 256 * 1024;
const MAX_NODES: usize = 2000;
const MAX_OPS: usize = 64;
const MAX_TABS: usize = 6;
const MAX_LOG: usize = 100;
const LIFETIMES: [&str; 4] = ["turn", "ephemeral", "pinned", "system"];

pub fn dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("HOMUN_STAGE").filter(|d| !d.is_empty()) {
        return dir.into();
    }
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join("claude/.homun/state/stage")
}

fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

pub struct Store {
    pub dir: PathBuf,
}

impl Store {
    fn file(
        &self,
        id: &str,
    ) -> PathBuf {
        self.dir.join(format!("{id}.json"))
    }

    fn journal(&self) -> Journal {
        Journal {
            dir: self.dir.clone(),
            stem: "events".into(),
            rotate_at: 1 << 20,
        }
    }

    fn lock<T>(
        &self,
        f: impl FnOnce() -> Result<T>,
    ) -> Result<T> {
        std::fs::create_dir_all(&self.dir)?;
        self.journal().locked(f)
    }

    pub fn get(
        &self,
        id: &str,
    ) -> Result<Value> {
        let text =
            std::fs::read_to_string(self.file(id)).map_err(|_| anyhow::anyhow!("no such scene"))?;
        Ok(serde_json::from_str(&text)?)
    }

    /// The open scenes, least recently used first.
    pub fn all(&self) -> Vec<Value> {
        let mut out: Vec<Value> = std::fs::read_dir(&self.dir)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
            .filter_map(|e| serde_json::from_str(&std::fs::read_to_string(e.path()).ok()?).ok())
            .collect();
        out.sort_by(|a, b| used(a).total_cmp(&used(b)));
        out
    }

    fn write(
        &self,
        scene: &Value,
        closed: bool,
    ) -> Result<()> {
        let id = text(scene, "id");
        let path = if closed {
            self.dir.join("closed").join(format!("{id}.json"))
        } else {
            self.file(&id)
        };
        std::fs::create_dir_all(path.parent().unwrap())?;
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec(scene)?)?;
        std::fs::rename(tmp, path)?;
        Ok(())
    }

    fn announce(
        &self,
        caller: &str,
        op: &str,
        scene: &Value,
    ) -> Result<()> {
        let id = text(scene, "id");
        let env = Envelope {
            id: format!("{id}-{}-{op}", scene["version"]),
            ts: now() as u64,
            from: caller.into(),
            to: "stage".into(),
            topic: format!("stage/{id}"),
            kind: Kind::Stage,
            body: json!({"op": op, "id": id, "version": scene["version"]}),
            reply_to: None,
            attn: None,
        };
        self.journal()
            .append_unlocked(&serde_json::to_string(&env)?)
    }

    fn make_room(
        &self,
        id: &str,
        caller: &str,
    ) -> Result<()> {
        let all = self.all();
        if all.iter().any(|s| text(s, "id") == id) || all.len() < MAX_TABS {
            return Ok(());
        }
        let Some(old) = all
            .iter()
            .find(|s| matches!(text(s, "lifetime").as_str(), "turn" | "ephemeral"))
        else {
            bail!("too many pinned or system scenes: id");
        };
        self.drop(caller, old)
    }

    fn drop(
        &self,
        caller: &str,
        scene: &Value,
    ) -> Result<()> {
        self.write(scene, true)?;
        std::fs::remove_file(self.file(&text(scene, "id")))?;
        self.announce(caller, "close", scene)
    }

    /// Create or replace the scene `id`; the new version.
    pub fn show(
        &self,
        caller: &str,
        id: &str,
        title: &str,
        lifetime: &str,
        root: Value,
    ) -> Result<u64> {
        if !id_ok(id) {
            bail!("id: [a-z0-9][a-z0-9_-]*, at most 64: id");
        }
        if !LIFETIMES.contains(&lifetime) {
            bail!("unknown lifetime: lifetime");
        }
        check_tree(&root)?;
        self.lock(|| {
            let old = self.get(id).ok();
            if let Some(old) = &old {
                may(caller, old)?;
            }
            self.make_room(id, caller)?;
            let version = old.as_ref().map_or(0, version) + 1;
            let mut scene = old.unwrap_or_else(|| json!({"owner_role": caller, "patches": []}));
            scene["id"] = id.into();
            scene["title"] = title.into();
            scene["lifetime"] = lifetime.into();
            scene["version"] = version.into();
            scene["used"] = now().into();
            scene["root"] = root.clone();
            log(
                &mut scene,
                json!({"show": true, "root": root, "version": version, "ts": now()}),
            );
            self.write(&scene, false)?;
            self.announce(caller, "show", &scene)?;
            Ok(version)
        })
    }

    pub fn patch(
        &self,
        caller: &str,
        id: &str,
        ops: &Value,
        if_version: Option<u64>,
    ) -> Result<u64> {
        self.lock(|| {
            let mut scene = self.get(id)?;
            may(caller, &scene)?;
            if if_version.is_some_and(|v| v != version(&scene)) {
                bail!("stale: version is {}: if_version", version(&scene));
            }
            let root = apply_ops(&scene["root"], ops)?;
            let next = version(&scene) + 1;
            scene["root"] = root;
            scene["version"] = next.into();
            scene["used"] = now().into();
            log(
                &mut scene,
                json!({"ops": ops, "version": next, "ts": now()}),
            );
            self.write(&scene, false)?;
            self.announce(caller, "patch", &scene)?;
            Ok(next)
        })
    }

    pub fn close(
        &self,
        caller: &str,
        id: &str,
    ) -> Result<()> {
        self.lock(|| {
            let scene = self.get(id)?;
            may(caller, &scene)?;
            self.drop(caller, &scene)
        })
    }

    /// Pin the scene, or with `off` return it to a turn scene.
    pub fn pin(
        &self,
        caller: &str,
        id: &str,
        off: bool,
    ) -> Result<()> {
        self.lock(|| {
            let mut scene = self.get(id)?;
            may(caller, &scene)?;
            scene["lifetime"] = (if off { "turn" } else { "pinned" }).into();
            self.write(&scene, false)?;
            self.announce(caller, "pin", &scene)
        })
    }

    /// Mark the scene used now (the Elisp store's "shown last").
    pub fn touch(
        &self,
        id: &str,
    ) -> Result<()> {
        self.lock(|| {
            let mut scene = self.get(id)?;
            scene["used"] = now().into();
            self.write(&scene, false)
        })
    }
}

fn text(
    v: &Value,
    key: &str,
) -> String {
    v[key].as_str().unwrap_or_default().to_string()
}

fn version(v: &Value) -> u64 {
    v["version"].as_u64().unwrap_or(0)
}

fn used(v: &Value) -> f64 {
    v["used"].as_f64().unwrap_or(0.0)
}

fn id_ok(id: &str) -> bool {
    let b = id.as_bytes();
    !b.is_empty()
        && b.len() <= 64
        && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit())
        && b.iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'_' || *c == b'-')
}

fn may(
    caller: &str,
    scene: &Value,
) -> Result<()> {
    if caller == "cal" || caller == text(scene, "owner_role") {
        Ok(())
    } else {
        bail!("not owner: id")
    }
}

fn log(
    scene: &mut Value,
    entry: Value,
) {
    let log = scene["patches"].as_array_mut().unwrap();
    log.push(entry);
    while log.len() > MAX_LOG {
        let old = log.remove(0);
        let next = &log[0];
        // The oldest entry keeps a root: fold the dropped one into its successor.
        if old.get("root").is_some() && next.get("root").is_none() && next.get("ops").is_some() {
            if let Ok(root) = apply_ops(&old["root"], &next["ops"]) {
                log[0]["root"] = root;
            }
        }
    }
}

fn count(node: &Value) -> usize {
    1 + node
        .as_object()
        .into_iter()
        .flat_map(|o| o.values())
        .filter_map(Value::as_array)
        .flatten()
        .filter(|c| c.get("type").is_some())
        .map(count)
        .sum::<usize>()
}

fn check_tree(root: &Value) -> Result<()> {
    if !root.is_object() {
        bail!("not an object: root");
    }
    if serde_json::to_vec(root)?.len() > MAX_BYTES {
        bail!("scene too large: root: max_bytes");
    }
    if count(root) > MAX_NODES {
        bail!("too many nodes: root: max_nodes");
    }
    Ok(())
}

fn find_mut<'a>(
    node: &'a mut Value,
    id: &str,
) -> Option<&'a mut Value> {
    if node.get("id").and_then(Value::as_str) == Some(id) {
        return Some(node);
    }
    node.as_object_mut()?
        .values_mut()
        .filter_map(Value::as_array_mut)
        .flatten()
        .find_map(|c| find_mut(c, id))
}

/// Remove the node `id` from the list that holds it.
fn remove_node(
    node: &mut Value,
    id: &str,
) -> bool {
    let Some(map) = node.as_object_mut() else {
        return false;
    };
    for list in map.values_mut().filter_map(Value::as_array_mut) {
        if let Some(at) = list
            .iter()
            .position(|c| c.get("id").and_then(Value::as_str) == Some(id))
        {
            list.remove(at);
            return true;
        }
        if list.iter_mut().any(|c| remove_node(c, id)) {
            return true;
        }
    }
    false
}

fn same_id(
    v: &Value,
    id: &str,
) -> bool {
    v.get("id").and_then(Value::as_str) == Some(id)
}

/// A new tree: `root` with `ops` applied, all or none.
pub fn apply_ops(
    root: &Value,
    ops: &Value,
) -> Result<Value> {
    let Some(ops) = ops.as_array().filter(|o| !o.is_empty()) else {
        bail!("ops: a non-empty list: ops");
    };
    if ops.len() > MAX_OPS {
        bail!("too many ops: ops: max_ops");
    }
    let mut tree = root.clone();
    for (i, op) in ops.iter().enumerate() {
        apply(&mut tree, op, i)?;
    }
    check_tree(&tree)?;
    Ok(tree)
}

fn apply(
    root: &mut Value,
    op: &Value,
    i: usize,
) -> Result<()> {
    let field = format!("ops/{i}");
    let Some(op) = op.as_object() else {
        bail!("not an object: {field}");
    };
    let verbs: Vec<&str> = ["set", "insert", "remove", "animate"]
        .into_iter()
        .filter(|k| op.contains_key(*k))
        .collect();
    if verbs.len() != 1 {
        bail!("one of set, insert, remove, animate: {field}");
    }
    let verb = verbs[0];
    let value = if verb == "animate" {
        match op["animate"].get("to") {
            Some(to) => to.clone(),
            None => bail!("animate needs to: {field}/animate"),
        }
    } else {
        op[verb].clone()
    };
    let segs: Vec<&str> = op
        .get("path")
        .and_then(Value::as_str)
        .and_then(|p| p.strip_prefix('/'))
        .map(|p| p.split('/').collect())
        .unwrap_or_default();
    if segs.is_empty() || segs.len() > 4 || segs.iter().any(|s| s.is_empty()) {
        bail!("bad path: {field}/path");
    }
    let at = |n: usize| format!("/{}", segs[..n].join("/"));
    if find_mut(root, segs[0]).is_none() {
        bail!("no such node: {}", at(1));
    }
    match segs.len() {
        1 => match verb {
            "set" | "animate" => {
                if !value.is_object() {
                    bail!("not an object: {field}");
                }
                *find_mut(root, segs[0]).unwrap() = value;
            }
            "remove" => {
                if same_id(root, segs[0]) || !remove_node(root, segs[0]) {
                    bail!("the root stays: {}", at(1));
                }
            }
            _ => bail!("insert needs a list path: {}", at(1)),
        },
        2 => {
            let node = find_mut(root, segs[0]).unwrap().as_object_mut();
            let Some(node) = node else {
                bail!("not an object: {}", at(1));
            };
            match verb {
                "remove" => {
                    node.shift_remove(segs[1]);
                }
                "insert" => bail!("insert needs a list path: {}", at(2)),
                _ => {
                    node.insert(segs[1].into(), value);
                }
            }
        }
        n => {
            let node = find_mut(root, segs[0]).unwrap();
            let Some(list) = node.get_mut(segs[1]).and_then(Value::as_array_mut) else {
                bail!("no such list: {}", at(2));
            };
            let pos = list.iter().position(|x| same_id(x, segs[2]));
            if segs[2] != "-" && pos.is_none() {
                bail!("no such item: {}", at(3));
            }
            if n == 3 {
                match verb {
                    "insert" => match pos {
                        Some(p) => list.insert(p, value),
                        None => list.push(value),
                    },
                    "remove" => match pos {
                        Some(p) => {
                            list.remove(p);
                        }
                        None => bail!("nothing to remove: {}", at(3)),
                    },
                    _ => {
                        let Some(p) = pos else {
                            bail!("use insert to append: {}", at(3));
                        };
                        if !value.is_object() {
                            bail!("not an object: {field}");
                        }
                        list[p] = value;
                    }
                }
            } else {
                let Some(p) = pos else {
                    bail!("no such item: {}", at(3));
                };
                let item = list[p].as_object_mut().unwrap();
                match verb {
                    "remove" => {
                        item.shift_remove(segs[3]);
                    }
                    "insert" => bail!("insert needs a list path: {}", at(4)),
                    _ => {
                        item.insert(segs[3].into(), value);
                    }
                }
            }
        }
    }
    Ok(())
}

fn fail(e: anyhow::Error) -> ExitCode {
    // "message: field[: limit]" as the Elisp refusal's (ERROR FIELD LIMIT).
    let mut parts = e
        .to_string()
        .splitn(3, ": ")
        .map(str::to_string)
        .collect::<Vec<_>>();
    let msg = parts.remove(0);
    let field = (!parts.is_empty()).then(|| parts.remove(0));
    println!(
        "{}",
        json!({"error": msg, "field": field, "limit": parts.first()})
    );
    ExitCode::from(1)
}

const HELP: &str = "homund stage: the Stage's scene store
  store <caller> <id> <title> <lifetime>       root JSON on stdin; {ok, version}
  patch <caller> <id> [if_version <n>]         ops JSON on stdin; {ok, version}
  close <caller> <id>
  pin <caller> <id> [off]
  touch <id>                                   mark the scene shown now
  get <id>                                     the record
  list                                         the open scenes, least recently used first
  subscribe                                    one envelope per open scene, then every change
  help
errors: {error, field, limit} on stdout, exit 1";

fn stdin() -> Result<Value> {
    let mut s = String::new();
    std::io::stdin().read_to_string(&mut s)?;
    Ok(serde_json::from_str(&s)?)
}

pub fn run(args: &[String]) -> ExitCode {
    let store = Store { dir: dir() };
    let a: Vec<&str> = args.iter().map(String::as_str).collect();
    let ok = |version: Option<u64>| {
        println!("{}", json!({"ok": true, "version": version}));
        ExitCode::SUCCESS
    };
    let result = match a.as_slice() {
        ["store", caller, id, title, lifetime] => stdin()
            .and_then(|root| store.show(caller, id, title, lifetime, root))
            .map(|v| ok(Some(v))),
        ["patch", caller, id, rest @ ..] => {
            let guard = match rest {
                [] => Some(None),
                ["if_version", n] => n.parse().ok().map(Some),
                _ => None,
            };
            match guard {
                Some(g) => stdin()
                    .and_then(|ops| store.patch(caller, id, &ops, g))
                    .map(|v| ok(Some(v))),
                None => return usage(),
            }
        }
        ["close", caller, id] => store.close(caller, id).map(|()| ok(None)),
        ["pin", caller, id] => store.pin(caller, id, false).map(|()| ok(None)),
        ["pin", caller, id, "off"] => store.pin(caller, id, true).map(|()| ok(None)),
        ["touch", id] => store.touch(id).map(|()| ok(None)),
        ["get", id] => store.get(id).map(|v| {
            println!("{v}");
            ExitCode::SUCCESS
        }),
        ["list"] => {
            for s in store.all() {
                println!("{s}");
            }
            Ok(ExitCode::SUCCESS)
        }
        ["subscribe"] => return subscribe(&store),
        ["help"] => {
            println!("{HELP}");
            Ok(ExitCode::SUCCESS)
        }
        _ => return usage(),
    };
    result.unwrap_or_else(fail)
}

fn usage() -> ExitCode {
    eprintln!("{HELP}");
    ExitCode::from(2)
}

/// An envelope per open scene (op `show`), then the new lines of events.jsonl, until killed.
fn subscribe(store: &Store) -> ExitCode {
    let journal = store.journal();
    let mut out = std::io::stdout().lock();
    let start = store
        .lock(|| {
            for s in store.all() {
                let id = text(&s, "id");
                let body = json!({"op": "show", "id": s["id"], "version": s["version"]});
                let env = json!({"id": format!("snap-{id}"), "ts": now() as u64, "from": "stage",
                    "to": "stage", "topic": format!("stage/{id}"), "kind": "stage", "body": body});
                writeln!(out, "{env}")?;
            }
            out.flush()?;
            Ok(std::fs::metadata(journal.path()).map_or(0, |m| m.len()))
        })
        .unwrap_or(0);
    let (mut off, mut ino) = (start, ino_of(&journal.path()));
    loop {
        std::thread::sleep(std::time::Duration::from_millis(100));
        let path = journal.path();
        if ino_of(&path) != ino {
            (off, ino) = (0, ino_of(&path));
        }
        let Ok(data) = std::fs::read(&path) else {
            continue;
        };
        if (data.len() as u64) < off {
            off = 0;
        }
        let rest = &data[off as usize..];
        let Some(end) = rest.iter().rposition(|b| *b == b'\n') else {
            continue;
        };
        for line in rest[..end].split(|b| *b == b'\n').filter(|l| !l.is_empty()) {
            if Envelope::parse(line).is_some()
                && (out.write_all(line).is_err() || out.write_all(b"\n").is_err())
            {
                return ExitCode::SUCCESS;
            }
        }
        off += end as u64 + 1;
        if out.flush().is_err() {
            return ExitCode::SUCCESS;
        }
    }
}

fn ino_of(path: &Path) -> u64 {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(path).map_or(0, |m| m.ino())
}

#[cfg(test)]
mod test {
    use super::*;

    fn tmp(name: &str) -> Store {
        let dir = std::env::temp_dir().join(format!("stage-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        Store { dir }
    }

    fn root() -> Value {
        json!({"type": "col", "id": "root", "children": [
            {"type": "text", "id": "t", "text": "Roll"},
            {"type": "stepper", "id": "s", "steps": ["pull"], "current": 0}]})
    }

    #[test]
    fn test_show_patch_persist() {
        let s = tmp("persist");
        assert_eq!(
            s.show("manager", "roll", "Roll", "turn", root()).unwrap(),
            1
        );
        let ops = json!([{"path": "/s/current", "set": 1}, {"path": "/root/children/-", "insert": {"type": "text", "id": "u", "text": "x"}}]);
        assert_eq!(s.patch("manager", "roll", &ops, Some(1)).unwrap(), 2);
        // a second store on the same dir is a restart: the scene is there
        let again = Store { dir: s.dir.clone() };
        let got = again.get("roll").unwrap();
        assert_eq!(got["version"], 2);
        assert_eq!(got["root"]["children"][1]["current"], 1);
        assert_eq!(got["root"]["children"][2]["id"], "u");
        assert_eq!(got["patches"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn test_refusals_change_nothing() {
        let s = tmp("refuse");
        s.show("manager", "roll", "Roll", "turn", root()).unwrap();
        let bad = json!([{"path": "/s/current", "set": 5}, {"path": "/zz/a", "set": 1}]);
        assert!(s.patch("manager", "roll", &bad, None).is_err());
        assert!(
            s.patch(
                "other",
                "roll",
                &json!([{"path": "/s/current", "set": 2}]),
                None
            )
            .is_err()
        );
        assert!(
            s.patch(
                "manager",
                "roll",
                &json!([{"path": "/s/current", "set": 2}]),
                Some(9)
            )
            .is_err()
        );
        assert_eq!(s.get("roll").unwrap()["root"]["children"][1]["current"], 0);
        assert!(s.close("other", "roll").is_err());
        s.close("cal", "roll").unwrap();
        assert!(s.get("roll").is_err() && s.dir.join("closed/roll.json").exists());
    }

    #[test]
    fn test_cap_closes_oldest_turn_scene() {
        let s = tmp("cap");
        for i in 0..7 {
            s.show("manager", &format!("s{i}"), "t", "turn", root())
                .unwrap();
        }
        assert_eq!(s.all().len(), MAX_TABS);
        assert!(s.dir.join("closed/s0.json").exists());
    }

    #[test]
    fn test_events_are_bus_envelopes() {
        let s = tmp("events");
        s.show("manager", "roll", "Roll", "turn", root()).unwrap();
        s.close("manager", "roll").unwrap();
        let lines = s.journal().lines().unwrap();
        let ops: Vec<String> = lines
            .iter()
            .map(|l| Envelope::parse(l).unwrap())
            .inspect(|e| assert_eq!((e.kind, e.topic.as_str()), (Kind::Stage, "stage/roll")))
            .map(|e| e.body["op"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(ops, ["show", "close"]);
    }
}
