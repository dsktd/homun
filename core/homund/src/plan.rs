//! `homund plan <role>`: a role's container as a pure function of the host's facts, the same
//! podman arguments, health check, preparation and plan-hash as `run.nu`'s `plan` (`homun
//! container plan`). Ad-hoc mounts and relays (homun.toml) are applied to the running
//! container, so they are not part of the plan: `live` only says whether the role takes them.

use std::collections::BTreeSet;
use std::path::Path;
use std::path::PathBuf;

use anyhow::Result;
use anyhow::anyhow;
use serde::Serialize;
use serde_json::Map;
use serde_json::Value;
use sha2::Digest;
use sha2::Sha256;

/// The role a bare `homun` attaches to; its container is not told its role.
pub const PRIMARY: &str = "manager";

const SCRATCH: &str = "/tmp/claude-0";
const SECRETS_DST: &str = "/run/claude-secrets";
const ROLES_MOUNT: &str = "/run/homun-roles";
const LOCALTIME: &str = "/etc/localtime";

/// Everything the plan reads from the host, gathered once by `Facts::gather`.
#[derive(Clone, Debug, Default)]
pub struct Facts {
    pub home: String,
    pub checkout: String,
    pub config_home: String,
    pub runtime: Option<String>,
    pub uid: u32,
    pub dbus: bool,
    pub hostcfg_file: String,
    pub hostcfg: Value,
    /// `~/.config/homun/homun.toml` (`$HOMUN_TOML`): the `gpu` and `kvm` the plan reads.
    pub homun_toml: Value,
    /// Every role, shipped and host-local, in the manifests' order.
    pub roles: Map<String, Value>,
    pub shipped: BTreeSet<String>,
    /// `/etc/localtime` with its symlinks resolved.
    pub localtime: Option<String>,
    pub cpuset_file: Option<String>,
    /// The paths among the ones the plan asks about that exist.
    pub present: BTreeSet<String>,
}

/// One container's plan.
#[derive(Clone, Debug, Serialize)]
pub struct PodmanSpec {
    pub name: String,
    pub role: String,
    pub args: Vec<String>,
    pub cmd: Vec<String>,
    pub health: Vec<String>,
    pub prep: Prep,
    pub live: bool,
}

/// What the host creates before `podman run`, so podman does not guess file or directory.
#[derive(Clone, Debug, Serialize)]
pub struct Prep {
    pub mkdirs: Vec<String>,
    pub touches: Vec<String>,
    pub seed: Option<Seed>,
}

#[derive(Clone, Debug, Serialize)]
pub struct Seed {
    pub src: String,
    pub dst: String,
}

/// A container: a seated role or the cockpit.
#[derive(Clone, Debug)]
struct Seat {
    role: String,
    name: String,
    state: String,
    notify: bool,
    wayland: bool,
    cockpit: bool,
    manifest: Value,
}

struct Mount {
    src: String,
    dst: String,
    mode: &'static str,
}

impl Mount {
    fn new(
        src: impl Into<String>,
        dst: impl Into<String>,
        mode: &'static str,
    ) -> Mount {
        Mount {
            src: src.into(),
            dst: dst.into(),
            mode,
        }
    }
}

/// What differs between the containers.
struct Shape {
    workdir: String,
    gh: bool,
    own_claude: bool,
    mkdirs: Vec<String>,
    env: Vec<String>,
    extra: Vec<Mount>,
    volumes: Vec<String>,
    seed: Option<Seed>,
}

fn join(
    base: &str,
    part: &str,
) -> String {
    format!("{base}/{part}")
}

fn get<'a>(
    value: &'a Value,
    path: &[&str],
) -> Option<&'a Value> {
    path.iter().try_fold(value, |v, key| v.get(key))
}

fn flag(
    value: &Value,
    path: &[&str],
) -> bool {
    get(value, path).and_then(Value::as_bool).unwrap_or(false)
}

fn text<'a>(
    value: &'a Value,
    path: &[&str],
) -> Option<&'a str> {
    get(value, path).and_then(Value::as_str)
}

/// `merge deep --strategy overwrite`: records merge key by key, anything else replaces.
fn merge(
    base: &mut Value,
    over: Value,
) {
    match (base, over) {
        (Value::Object(base), Value::Object(over)) => {
            for (key, value) in over {
                match base.get_mut(&key) {
                    Some(slot) => merge(slot, value),
                    None => {
                        base.insert(key, value);
                    }
                }
            }
        }
        (base, over) => *base = over,
    }
}

impl Facts {
    fn root(&self) -> String {
        join(&self.home, "claude")
    }

    fn state(&self) -> String {
        join(&self.home, ".local/share/claude")
    }

    fn config(&self) -> String {
        join(&self.home, ".config/claude")
    }

    fn roles_dir(&self) -> String {
        join(&self.config_home, "homun/roles")
    }

    fn has(
        &self,
        path: &str,
    ) -> bool {
        self.present.contains(path)
    }

    fn enabled(
        &self,
        key: &str,
    ) -> bool {
        let listed = self
            .hostcfg
            .get("roles")
            .and_then(Value::as_array)
            .is_some_and(|roles| roles.iter().any(|r| r.as_str() == Some(key)));
        key == PRIMARY
            || key == "editor"
            || !self.shipped.contains(key)
            || self.has(&join(&self.config(), key))
            || listed
    }

    fn gpu(&self) -> bool {
        flag(&self.homun_toml, &["gpu"]) || flag(&self.hostcfg, &["gpu"])
    }

    fn kvm(&self) -> bool {
        flag(&self.homun_toml, &["kvm"]) || flag(&self.hostcfg, &["kvm"])
    }

    fn cpuset(&self) -> String {
        match &self.cpuset_file {
            Some(cpuset) => cpuset.trim().to_string(),
            None => text(&self.hostcfg, &["cpuset"]).unwrap_or("").to_string(),
        }
    }

    /// The host config's `cockpit.config`, expanded.
    fn cockpit_config(&self) -> Option<String> {
        let dir = text(&self.hostcfg, &["cockpit", "config"])?;
        let dir = match dir.strip_prefix('~') {
            Some(rest) => format!("{}{rest}", self.home),
            None => dir.to_string(),
        };
        Some(dir.trim_end_matches('/').to_string())
    }

    /// The containers with a role, in the manifests' order.
    fn seats(&self) -> Vec<Seat> {
        self.roles
            .iter()
            .filter_map(|(role, manifest)| {
                let seat = manifest.get("seat");
                let default = if flag(manifest, &["container"]) {
                    "container"
                } else {
                    "none"
                };
                let kind = seat.and_then(|s| text(s, &["kind"])).unwrap_or(default);
                if kind != "container" {
                    return None;
                }
                let name = seat
                    .and_then(|s| text(s, &["name"]))
                    .map(str::to_string)
                    .unwrap_or_else(|| format!("homun-{role}"));
                let state = match seat.and_then(|s| text(s, &["state"])).unwrap_or(role) {
                    "" => self.state(),
                    state => join(&self.state(), state),
                };
                Some(Seat {
                    role: role.clone(),
                    name,
                    state,
                    notify: flag(manifest, &["access", "notify"]),
                    wayland: flag(manifest, &["access", "wayland"]),
                    cockpit: false,
                    manifest: manifest.clone(),
                })
            })
            .collect()
    }

    fn editor(&self) -> Seat {
        Seat {
            role: "editor".into(),
            name: "claude-emacs".into(),
            state: join(&self.state(), "emacs"),
            notify: true,
            wayland: true,
            cockpit: true,
            manifest: Value::Null,
        }
    }

    /// Every container `homun container plan` knows: the primary, the cockpit, the others.
    fn containers(&self) -> Vec<Seat> {
        let seats = self.seats();
        let primary = seats.iter().filter(|s| s.role == PRIMARY).cloned();
        let others = seats.iter().filter(|s| s.role != PRIMARY).cloned();
        primary.chain([self.editor()]).chain(others).collect()
    }

    fn bus_roles(&self) -> Vec<String> {
        let mut roles = vec![PRIMARY.to_string()];
        for seat in self.containers() {
            if seat.role != PRIMARY && self.enabled(&seat.role) && !roles.contains(&seat.role) {
                roles.push(seat.role);
            }
        }
        roles
    }

    fn bus(&self) -> String {
        join(&self.root(), ".services/bus")
    }

    fn inboxes(&self) -> Vec<String> {
        [
            ".services/mechanic/cal-inbox",
            ".services/update/emacs-request",
            ".services/host/requests/cockpit",
            ".services/approve/answers",
            ".services/compact/emacs-request",
        ]
        .iter()
        .map(|d| join(&self.root(), d))
        .collect()
    }

    fn secrets(&self) -> String {
        join(&self.home, ".local/share/claude-secrets/inbox")
    }

    fn mkdirs(&self) -> Vec<String> {
        let root = self.root();
        let mut dirs = vec![root.clone(), join(&root, ".bare"), join(&root, ".services")];
        dirs.extend(self.inboxes());
        dirs.push(join(&self.bus(), "user"));
        for role in self.bus_roles() {
            let dir = join(&self.bus(), &role);
            dirs.extend([
                dir.clone(),
                join(&dir, "user/host"),
                join(&dir, "user-state"),
            ]);
        }
        dirs
    }

    fn volumes(&self) -> Vec<String> {
        let home = &self.home;
        vec![
            "--volume=claude-nix:/nix".into(),
            format!("--volume=claude-nix-cache:{home}/.cache/nix"),
            format!("--volume=claude-code:{home}/.local/share/claude"),
            format!("--volume=claude-code-bin:{home}/.local/bin"),
        ]
    }

    /// Another role's Claude state, read-only, its credentials masked; only once it exists.
    fn state_mounts(
        &self,
        src: &str,
        dst: &str,
    ) -> Vec<Mount> {
        if !self.has(src) {
            return vec![];
        }
        vec![
            Mount::new(src, dst, "ro"),
            Mount::new("/dev/null", join(dst, ".credentials.json"), "ro"),
        ]
    }

    fn cockpit_shape(
        &self,
        seat: &Seat,
        seats: &[Seat],
    ) -> Result<Shape> {
        let root = self.root();
        let config = self.cockpit_config();
        let mut env = vec!["--env".into(), format!("CLAUDE_ROLE={}", seat.role)];
        let mut extra = vec![];
        if let Some(config) = &config {
            env.extend(["--env".into(), format!("HOMUN_COCKPIT_CONFIG={config}")]);
            if self.has(config) && !config.starts_with(&format!("{root}/")) {
                extra.push(Mount::new(config, config, "ro"));
            }
        }
        let primary = seats
            .iter()
            .find(|s| s.role == PRIMARY)
            .ok_or_else(|| anyhow!("no {PRIMARY} role"))?;
        extra.push(Mount::new(self.secrets(), SECRETS_DST, "rw"));
        extra.push(Mount::new(
            join(&primary.state, "claude"),
            join(&self.home, ".claude"),
            "ro",
        ));
        extra.push(Mount::new(
            "/dev/null",
            join(&self.home, ".claude/.credentials.json"),
            "ro",
        ));
        for other in seats.iter().filter(|s| s.role != PRIMARY) {
            let dst = format!("/mnt/{}-claude", other.role);
            extra.extend(self.state_mounts(&join(&other.state, "claude"), &dst));
        }
        let mut mkdirs = self.mkdirs();
        mkdirs.push(self.secrets());
        Ok(Shape {
            workdir: root,
            gh: false,
            own_claude: false,
            mkdirs,
            env,
            extra,
            volumes: self.volumes(),
            seed: None,
        })
    }

    fn role_shape(
        &self,
        seat: &Seat,
        seats: &[Seat],
    ) -> Result<Shape> {
        let manifest = &seat.manifest;
        let at = |path: &str| {
            for (prefix, with) in [
                ("@root", self.root()),
                ("@home", self.home.clone()),
                ("@state", seat.state.clone()),
            ] {
                if let Some(rest) = path.strip_prefix(prefix) {
                    return format!("{with}{rest}");
                }
            }
            path.to_string()
        };
        let secrets = text(manifest, &["access", "secrets"]);
        let own_state = join(&self.bus(), &format!("{}/user-state", seat.role));

        let mut extra: Vec<Mount> = self
            .inboxes()
            .into_iter()
            .map(|d| Mount::new(&d, d.clone(), "ro"))
            .collect();
        let roles = self.bus_roles();
        let user = roles
            .iter()
            .map(|r| join(&self.bus(), &format!("{r}/user")));
        let states = roles
            .iter()
            .map(|r| join(&self.bus(), &format!("{r}/user-state")));
        for dir in user.chain(states.filter(|d| *d != own_state)) {
            extra.push(Mount::new(&dir, dir.clone(), "ro"));
        }
        if let Some(mode) = secrets {
            let mode = if mode == "rw" { "rw" } else { "ro" };
            extra.push(Mount::new(self.secrets(), SECRETS_DST, mode));
        }
        let read = get(manifest, &["access", "read_state_of"]).and_then(Value::as_array);
        for entry in read.into_iter().flatten() {
            let key = entry
                .as_str()
                .or_else(|| text(entry, &["role"]))
                .unwrap_or("");
            let other = seats
                .iter()
                .find(|s| s.role == key)
                .ok_or_else(|| anyhow!("read_state_of: no container role {key}"))?;
            let src = join(&other.state, "claude");
            let dst = match text(entry, &["at"]) {
                Some("@host") => src.clone(),
                _ => format!("/mnt/{key}-claude"),
            };
            extra.extend(self.state_mounts(&src, &dst));
        }

        let mut volumes = self.volumes();
        let named = get(manifest, &["access", "volumes"]).and_then(Value::as_array);
        for volume in named.into_iter().flatten() {
            let name = text(volume, &["name"]).unwrap_or("");
            volumes.push(format!(
                "--volume={name}:{}",
                at(text(volume, &["at"]).unwrap_or(""))
            ));
        }

        let mut mkdirs = self.mkdirs();
        if secrets.is_some() {
            mkdirs.push(self.secrets());
        }
        let seed = get(manifest, &["session", "seed"]).map(|seed| Seed {
            src: join(&self.checkout, text(seed, &["src"]).unwrap_or("")),
            dst: at(text(seed, &["dst"]).unwrap_or("")),
        });
        let env = if seat.role == PRIMARY {
            vec![]
        } else {
            vec!["--env".into(), format!("CLAUDE_ROLE={}", seat.role)]
        };
        Ok(Shape {
            workdir: at(text(manifest, &["session", "workdir"]).unwrap_or("@root")),
            gh: flag(manifest, &["access", "gh"]),
            own_claude: true,
            mkdirs,
            env,
            extra,
            volumes,
            seed,
        })
    }

    /// The host's timezone name, from where /etc/localtime resolves to.
    fn timezone(&self) -> Option<String> {
        let resolved = self.localtime.as_deref()?;
        let parts: Vec<&str> = resolved.split('/').filter(|p| !p.is_empty()).collect();
        let at = parts.iter().position(|p| *p == "zoneinfo")?;
        let zone = &parts[at + 1..];
        if zone.is_empty() {
            None
        } else {
            Some(zone.join("/"))
        }
    }

    fn health(
        &self,
        seat: &Seat,
    ) -> Vec<String> {
        let cmd = if seat.cockpit {
            format!(
                "/nix/var/nix/profiles/emacs/bin/emacsclient -s {}/.services/emacs/socket -e t",
                self.root()
            )
        } else {
            text(&seat.manifest, &["health"])
                .unwrap_or("")
                .replace("@root", &self.root())
        };
        let mut health = vec![];
        if text(&seat.manifest, &["restart"]) != Some("none") {
            health.push("--restart=on-failure:5".into());
        }
        if !cmd.is_empty() {
            health.extend([
                format!("--health-cmd={cmd}"),
                "--health-interval=30s".into(),
                "--health-timeout=10s".into(),
                "--health-retries=3".into(),
                "--health-start-period=10m".into(),
            ]);
        }
        health
    }

    fn runtime_dir(&self) -> String {
        match self.runtime.as_deref() {
            Some(dir) if !dir.is_empty() => dir.to_string(),
            _ => format!("/tmp/homun-{}", self.uid),
        }
    }

    /// The plan of one container, by its role key (`editor` is the cockpit).
    pub fn plan(
        &self,
        key: &str,
    ) -> Result<PodmanSpec> {
        let containers = self.containers();
        let Some(seat) = containers.iter().find(|s| s.role == key) else {
            let keys: Vec<&str> = containers.iter().map(|s| s.role.as_str()).collect();
            return Err(anyhow!("unknown role '{key}'; one of: {}", keys.join(", ")));
        };
        let seats = self.seats();
        let shape = if seat.cockpit {
            self.cockpit_shape(seat, &seats)?
        } else {
            self.role_shape(seat, &seats)?
        };
        let home = &self.home;
        let state = &seat.state;
        let notify = match (&self.runtime, self.dbus && seat.notify) {
            (Some(runtime), true) => Some(join(runtime, "homun-bus")),
            _ => None,
        };
        let wayland = seat
            .wayland
            .then(|| join(&self.runtime_dir(), "claude-wayland.d"));

        let mut dirs = vec![];
        let mut files = vec![];
        if shape.own_claude {
            dirs.push((join(state, "claude"), join(home, ".claude")));
            files.push((join(state, "claude.json"), join(home, ".claude.json")));
        }
        if shape.gh {
            dirs.push((join(state, "gh"), join(home, ".config/gh")));
        }
        dirs.push((join(state, "git"), join(home, ".config/git")));
        dirs.push((join(state, "scratch"), SCRATCH.into()));

        let mut mounts = vec![Mount::new(self.root(), self.root(), "rw")];
        // Claude's state first (its files after its directory), as run.nu lists them
        let mut own: Vec<Mount> = vec![];
        let mut dir_iter = dirs.iter();
        if shape.own_claude {
            let (src, dst) = dir_iter.next().expect("own claude dir");
            own.push(Mount::new(src, dst, "rw"));
            for (src, dst) in &files {
                own.push(Mount::new(src, dst, "rw"));
            }
        }
        own.extend(dir_iter.map(|(src, dst)| Mount::new(src, dst, "rw")));
        mounts.extend(own);

        if self.has(&join(&self.checkout, "container/entrypoint.sh")) {
            mounts.push(Mount::new(
                join(&self.checkout, "container"),
                "/opt/homun",
                "ro",
            ));
        }
        let agent = join(&self.config(), "agent.json");
        if self.has(&agent) {
            mounts.push(Mount::new(agent, "/run/claude-agent.json", "ro"));
        }
        if self.has(&self.hostcfg_file) {
            mounts.push(Mount::new(
                &self.hostcfg_file,
                "/run/claude-config.json",
                "ro",
            ));
        }
        if self.has(&self.roles_dir()) {
            mounts.push(Mount::new(self.roles_dir(), ROLES_MOUNT, "ro"));
        }
        if let Some(localtime) = &self.localtime {
            mounts.push(Mount::new(localtime, LOCALTIME, "ro"));
        }
        if let Some(socket) = &notify {
            mounts.push(Mount::new(socket, "/run/homun-bus", "rw"));
        }
        if let Some(socket) = &wayland {
            mounts.push(Mount::new(socket, "/run/claude-wayland.d", "rw"));
        }
        mounts.extend(shape.extra);

        let mut args = vec![
            format!("--name={}", seat.name),
            format!("--hostname={}", seat.name),
            format!("--workdir={}", shape.workdir),
        ];
        for env in [
            "PS1=\x1b[1;35m\\h\x1b[0m$ ".to_string(),
            "ENABLE_LSP_TOOL=1".into(),
            "COLORTERM=truecolor".into(),
            format!("HOME={home}"),
        ] {
            args.extend(["--env".into(), env]);
        }
        args.extend(shape.env);
        if let Some(zone) = self.timezone() {
            args.extend(["--env".into(), format!("TZ={zone}")]);
        }
        if notify.is_some() {
            args.extend([
                "--env".into(),
                "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/homun-bus/bus".into(),
            ]);
        }
        args.extend(
            mounts
                .iter()
                .map(|m| format!("--volume={}:{}:{}", m.src, m.dst, m.mode)),
        );
        args.extend(shape.volumes);
        if self.gpu() {
            args.extend(["--device", "/dev/dri", "--group-add", "keep-groups"].map(String::from));
            args.push(format!(
                "--security-opt=seccomp={}",
                join(&self.checkout, "seccomp.json")
            ));
        }
        if self.kvm() {
            args.extend(["--device", "/dev/kvm"].map(String::from));
            if !self.gpu() {
                args.extend(["--group-add", "keep-groups"].map(String::from));
            }
        }
        args.push("--security-opt=unmask=/proc/*".into());
        let cpuset = self.cpuset();
        if flag(&seat.manifest, &["access", "cpuset"]) && !cpuset.is_empty() {
            args.push(format!("--cpuset-cpus={cpuset}"));
        }

        let mut mkdirs = shape.mkdirs;
        mkdirs.extend(dirs.into_iter().map(|(src, _)| src));
        let mut touches: Vec<String> = files.into_iter().map(|(src, _)| src).collect();
        touches.push(join(state, "git/config"));

        Ok(PodmanSpec {
            name: seat.name.clone(),
            role: seat.role.clone(),
            args,
            cmd: if seat.cockpit {
                vec!["sh".into(), "/opt/homun/emacs-container.sh".into()]
            } else {
                vec![]
            },
            health: self.health(seat),
            prep: Prep {
                mkdirs,
                touches,
                seed: shape.seed,
            },
            live: flag(&seat.manifest, &["access", "live_mounts"]),
        })
    }
}

impl PodmanSpec {
    /// The `claude.plan` label: the first 16 hex digits of the SHA-256 of `args` as compact JSON.
    pub fn hash(&self) -> String {
        let json = serde_json::to_string(&self.args).expect("strings serialize");
        let digest = Sha256::digest(json.as_bytes());
        digest.iter().take(8).map(|b| format!("{b:02x}")).collect()
    }
}

fn env(key: &str) -> Option<String> {
    std::env::var_os(key).map(|value| value.to_string_lossy().into_owned())
}

fn read_json(path: &Path) -> Result<Value> {
    Ok(serde_json::from_str(&std::fs::read_to_string(path)?)?)
}

impl Facts {
    /// The facts of this host, from the environment and the files `run.nu` reads; `checkout` is
    /// the Homun checkout (its roles/roles.toml and container/).
    pub fn gather(checkout: &Path) -> Result<Facts> {
        use std::os::unix::fs::MetadataExt;

        let home = env("HOME").ok_or_else(|| anyhow!("HOME is not set"))?;
        let checkout = std::path::absolute(checkout)?
            .to_string_lossy()
            .into_owned();
        let config_home = env("XDG_CONFIG_HOME").unwrap_or_else(|| join(&home, ".config"));
        let hostcfg_file = env("HOMUN_CONFIG")
            .unwrap_or_else(|| join(&home, ".config/claude/config.json"));
        let mut facts = Facts {
            home,
            checkout,
            config_home,
            runtime: env("XDG_RUNTIME_DIR"),
            uid: std::fs::metadata("/proc/self")?.uid(),
            dbus: env("DBUS_SESSION_BUS_ADDRESS").is_some(),
            hostcfg_file,
            ..Facts::default()
        };
        let hostcfg = Path::new(&facts.hostcfg_file);
        facts.hostcfg = if hostcfg.exists() {
            read_json(hostcfg)?
        } else {
            Value::Object(Map::new())
        };

        let homun_toml = env("HOMUN_TOML").unwrap_or_else(|| join(&facts.home, ".config/homun/homun.toml"));
        if let Ok(text) = std::fs::read_to_string(homun_toml) {
            facts.homun_toml = serde_json::to_value(toml::from_str::<toml::Value>(&text)?)?;
        }

        let toml = std::fs::read_to_string(join(&facts.checkout, "roles/roles.toml"))?;
        let shipped: Map<String, Value> = toml::from_str(&toml)?;
        let mut ordered: Vec<(&String, &Value)> = shipped.iter().collect();
        let order = |m: &Value| m.get("order").and_then(Value::as_i64).unwrap_or(1000);
        ordered.sort_by(|a, b| order(a.1).cmp(&order(b.1)).then(a.0.cmp(b.0)));
        let mut roles = Value::Object(
            ordered
                .into_iter()
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect(),
        );
        facts.shipped = shipped.keys().cloned().collect();
        let dir = PathBuf::from(facts.roles_dir());
        if dir.is_dir() {
            let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)?
                .filter_map(|entry| entry.ok().map(|e| e.path()))
                .filter(|path| path.extension().is_some_and(|e| e == "json"))
                .collect();
            files.sort();
            let mut local = Map::new();
            for file in files {
                let Some(stem) = file.file_stem() else {
                    continue;
                };
                local.insert(stem.to_string_lossy().into_owned(), read_json(&file)?);
            }
            merge(&mut roles, Value::Object(local));
        }
        let Value::Object(roles) = roles else {
            unreachable!()
        };
        facts.roles = roles;

        facts.localtime = std::fs::canonicalize(LOCALTIME)
            .ok()
            .map(|p| p.to_string_lossy().into_owned());
        facts.cpuset_file = std::fs::read_to_string(join(&facts.config(), "cpuset")).ok();

        let mut probe = vec![
            join(&facts.checkout, "container/entrypoint.sh"),
            join(&facts.config(), "agent.json"),
            facts.hostcfg_file.clone(),
            facts.roles_dir(),
        ];
        probe.extend(facts.cockpit_config());
        for seat in facts.seats() {
            probe.push(join(&seat.state, "claude"));
        }
        for key in facts.roles.keys() {
            probe.push(join(&facts.config(), key));
        }
        facts.present = probe
            .into_iter()
            .filter(|p| Path::new(p).exists())
            .collect();
        Ok(facts)
    }
}
