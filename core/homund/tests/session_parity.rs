//! `homund session broker` against container/session-broker, offline, on the same script: a fake
//! claude (tests/fixtures/fake-claude, a scripted stream-json emitter) is driven through a start,
//! an Emacs compact, an interrupt, a restart (claude exits and is resumed), a recycle (the fresh
//! marker and a SIGTERM), a stream rotation forced mid-turn and one more turn. Each broker must
//! keep every line the fake printed exactly once and in order, across the rotation, and both must
//! write the same stream, turn index, starts and compact answer.

use std::fs;
use std::io::Write;
use std::path::Path;
use std::path::PathBuf;
use std::process::Child;
use std::process::Command;
use std::time::Duration;
use std::time::Instant;

use serde_json::Value;

fn checkout() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap()
}

fn lines(path: &Path) -> Vec<Value> {
    fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap_or_else(|_| panic!("{}: {l}", path.display())))
        .collect()
}

struct Run {
    home: PathBuf,
    fake: PathBuf,
    stream: PathBuf,
    child: Child,
}

impl Run {
    fn start(
        name: &str,
        new: bool,
    ) -> Self {
        let home =
            std::env::temp_dir().join(format!("homund-session-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&home);
        let (bin, fake, stream) = (home.join("bin"), home.join("fake"), home.join("stream"));
        for d in [
            &bin,
            &fake,
            &stream,
            &home.join(".claude/projects"),
            &home.join("compact/emacs-request"),
        ] {
            fs::create_dir_all(d).unwrap();
        }
        let root = checkout();
        std::os::unix::fs::symlink(
            root.join("core/homund/tests/fixtures/fake-claude"),
            bin.join("claude"),
        )
        .unwrap();
        let mut cmd = if new {
            let mut c = Command::new(env!("CARGO_BIN_EXE_homund"));
            c.args(["session", "broker"]);
            c
        } else {
            let mut c = Command::new("python3");
            c.arg("-I").arg(root.join("container/session-broker"));
            c
        };
        let path = format!(
            "{}:{}",
            bin.display(),
            std::env::var("PATH").unwrap_or_default()
        );
        cmd.arg(&stream)
            .args(["--name", "Tester"])
            .env("PATH", path)
            .env("HOME", &home)
            .env("TZ", "UTC0")
            .env("FAKE_DIR", &fake)
            .env("BROKER_SESSION_FILE", home.join(".claude/tester-session"))
            .env("BROKER_PROMPT", "hello")
            .env("BROKER_FRESH", home.join("fresh"))
            .env("BROKER_COMPACT", "1")
            .env("BROKER_ROLE", "tester")
            .env("BROKER_ROTATE_BYTES", "20000")
            .env("BROKER_STATUSLINE", "/dev/null")
            .env("COMPACT_DIR", home.join("compact"))
            .env("APPROVE_DIR", home.join("approve"))
            .env_remove("BROKER_SESSION")
            .env_remove("BROKER_WORKDIR");
        let child = cmd.spawn().unwrap();
        Self {
            home,
            fake,
            stream,
            child,
        }
    }

    fn emitted(&self) -> Vec<Value> {
        lines(&self.fake.join("emitted.jsonl"))
    }

    fn results(&self) -> usize {
        self.emitted()
            .iter()
            .filter(|e| e["type"] == "result")
            .count()
    }

    fn starts(&self) -> Vec<Value> {
        lines(&self.fake.join("starts.jsonl"))
    }

    fn wait(
        &self,
        what: &str,
        done: impl Fn(&Self) -> bool,
    ) {
        let deadline = Instant::now() + Duration::from_secs(30);
        while !done(self) {
            assert!(
                Instant::now() < deadline,
                "{}: timed out waiting for {what}",
                self.home.display()
            );
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    fn say(
        &self,
        line: &str,
    ) {
        let fifo = self.stream.join("in");
        self.wait("the FIFO", |_| fifo.exists());
        let mut f = fs::OpenOptions::new().write(true).open(&fifo).unwrap();
        writeln!(f, "{line}").unwrap();
    }

    /// The whole script; returns the broker's stream, both generations, oldest first.
    fn drive(mut self) -> Outcome {
        self.wait("the first turn", |r| r.results() == 1);

        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        fs::write(
            self.home.join("compact/emacs-request/request"),
            format!("{stamp} compact\n"),
        )
        .unwrap();
        self.wait("the compact", |r| r.results() == 2);
        let compact =
            fs::read_to_string(self.home.join("compact/emacs-result")).unwrap_or_default();

        self.say("slow");
        self.wait("the slow turn", |r| {
            r.emitted()
                .iter()
                .any(|e| e["event"]["delta"]["text"] == "thinking")
        });
        self.say("/interrupt");
        self.wait("the interrupt", |r| r.results() == 3);

        self.say("exit");
        self.wait("the restart", |r| {
            r.starts().len() == 2 && !r.emitted().is_empty()
        });
        self.wait("the resumed init", |r| {
            r.emitted().last().is_some_and(|e| e["subtype"] == "init")
        });

        fs::write(self.home.join("fresh"), "").unwrap();
        let pid: i32 = fs::read_to_string(self.fake.join("pid"))
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        // SAFETY: a plain kill(2) of the fake claude this test started through the broker.
        unsafe { libc::kill(pid, libc::SIGTERM) };
        self.wait("the fresh start", |r| {
            r.starts().len() == 3 && r.results() == 5
        });

        self.say("big");
        self.wait("the big turn", |r| r.results() == 6);
        self.say("ping");
        self.wait("the last turn", |r| r.results() == 7);

        // SAFETY: SIGTERM to the broker this test started.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        let deadline = Instant::now() + Duration::from_secs(15);
        while self.child.try_wait().unwrap().is_none() {
            assert!(Instant::now() < deadline, "the broker did not stop");
            std::thread::sleep(Duration::from_millis(50));
        }
        let mut stream = lines(&self.stream.join("stream.jsonl.1"));
        let rotated = !stream.is_empty();
        stream.extend(lines(&self.stream.join("stream.jsonl")));
        Outcome {
            rotated,
            emitted: self.emitted(),
            starts: self.starts(),
            turns: fs::read_to_string(self.stream.join("turns")).unwrap_or_default(),
            compact: compact
                .split_once(' ')
                .map(|(_, w)| w.trim().to_owned())
                .unwrap_or_default(),
            stream,
        }
    }
}

struct Outcome {
    rotated: bool,
    emitted: Vec<Value>,
    stream: Vec<Value>,
    starts: Vec<Value>,
    turns: String,
    compact: String,
}

impl Outcome {
    fn claude_lines(&self) -> Vec<&Value> {
        self.stream
            .iter()
            .filter(|e| e["type"] != "broker")
            .collect()
    }

    /// The stream without what differs by run: times, ids and the broker's own error texts.
    fn shape(&self) -> Vec<String> {
        self.stream
            .iter()
            .map(|e| {
                let mut e = e.clone();
                if let Value::Object(o) = &mut e {
                    o.remove("ts");
                    o.remove("session_id");
                }
                if let Some(id) = e.pointer_mut("/response/request_id") {
                    *id = Value::from("<random>");
                }
                e.to_string()
            })
            .collect()
    }

    /// The session picks, ids replaced by their order of first appearance.
    fn picks(&self) -> Vec<String> {
        let mut ids: Vec<&str> = vec![];
        self.starts
            .iter()
            .map(|s| {
                let id = s["session"].as_str().unwrap_or("");
                if !ids.contains(&id) {
                    ids.push(id);
                }
                let n = ids.iter().position(|i| *i == id).unwrap();
                format!("{} {n}", s["pick"].as_str().unwrap_or("-"))
            })
            .collect()
    }

    fn check(
        &self,
        name: &str,
    ) {
        let kept = self.claude_lines();
        let printed: Vec<&Value> = self.emitted.iter().collect();
        assert_eq!(
            kept, printed,
            "{name}: the stream is not what claude printed (lost or doubled lines)"
        );
        assert!(self.rotated, "{name}: the stream did not rotate");
        assert_eq!(self.compact, "ok", "{name}: the compact answer");
        let picks = self.picks();
        assert_eq!(
            picks,
            ["--session-id 0", "--resume 0", "--session-id 1"],
            "{name}: the starts"
        );
        let notes: Vec<&str> = self
            .stream
            .iter()
            .filter(|e| e["type"] == "broker")
            .filter_map(|e| e["subtype"].as_str())
            .collect();
        assert_eq!(
            notes,
            ["exit", "exit", "fresh", "exit"],
            "{name}: the broker's notes"
        );
        let first: Vec<&Value> = kept
            .iter()
            .copied()
            .filter(|e| e["type"] == "user")
            .collect();
        let texts: Vec<&str> = first
            .iter()
            .filter_map(|e| e["message"]["content"].as_str())
            .collect();
        assert_eq!(
            texts,
            [
                "hello",
                "/compact",
                "slow",
                "[Request interrupted by user]",
                "exit",
                "hello",
                "big",
                "ping"
            ],
            "{name}: the turns (a first prompt only on a new session, never on a resume)"
        );
    }
}

#[test]
fn broker_parity_start_compact_interrupt_restart_recycle_rotate() {
    let old = std::thread::spawn(|| Run::start("old", false).drive());
    let new = std::thread::spawn(|| Run::start("new", true).drive());
    let (old, new) = (old.join().unwrap(), new.join().unwrap());
    old.check("session-broker");
    new.check("homund session broker");
    // Offsets differ by the width of the broker's own notes; the index's shape may not
    let shape = |t: &str| t.lines().map(|l| l == "0").collect::<Vec<_>>();
    assert_eq!(shape(&old.turns), shape(&new.turns), "the turn index");
    assert_eq!(
        shape(&new.turns).first(),
        Some(&true),
        "the index restarts at the rotation"
    );
    assert_eq!(old.shape(), new.shape(), "the two streams differ");
}

/// The interactive kind: compact-relay and `homund session relay` on a pty, around a fake TUI
/// that writes the line it is typed; the Emacs request must type `/compact` once it is idle.
fn relay_compacts(new: bool) -> (String, String) {
    let name = if new { "relay-new" } else { "relay-old" };
    let home = std::env::temp_dir().join(format!("homund-session-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&home);
    let services = home.join("claude/.services");
    fs::create_dir_all(services.join("compact/emacs-request")).unwrap();
    fs::create_dir_all(services.join("busy")).unwrap();
    fs::write(services.join("busy/status"), r#"{"state":"idle"}"#).unwrap();
    let got = home.join("got");
    let tui = format!("read l; printf '%s' \"$l\" > {}", got.display());
    let (mut master, mut slave) = (0, 0);
    // SAFETY: openpty(3) into two descriptors of our own.
    let opened = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null(),
            std::ptr::null(),
        )
    };
    assert_eq!(opened, 0, "openpty");
    let tty = || {
        // SAFETY: dup(2) of the slave, owned by the Stdio it becomes.
        unsafe { std::process::Stdio::from(std::os::fd::OwnedFd::from_raw_fd(libc::dup(slave))) }
    };
    use std::os::fd::FromRawFd;
    let mut cmd = if new {
        let mut c = Command::new(env!("CARGO_BIN_EXE_homund"));
        c.args(["session", "relay"]);
        c
    } else {
        let mut c = Command::new("python3");
        c.arg("-I").arg(checkout().join("container/compact-relay"));
        c
    };
    let mut child = cmd
        .args(["sh", "-c", &tui])
        .env("HOME", &home)
        .stdin(tty())
        .stdout(tty())
        .stderr(tty())
        .spawn()
        .unwrap();
    std::thread::sleep(Duration::from_millis(1500)); // past the request read at its start
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    fs::write(
        services.join("compact/emacs-request/request"),
        format!("{stamp} compact\n"),
    )
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(15);
    while child.try_wait().unwrap().is_none() {
        assert!(
            Instant::now() < deadline,
            "{name}: the TUI was not typed to"
        );
        let mut buf = [0u8; 4096];
        // SAFETY: draining the pty master so the relay never blocks on output.
        unsafe {
            let mut p = libc::pollfd {
                fd: master,
                events: libc::POLLIN,
                revents: 0,
            };
            if libc::poll(&mut p, 1, 50) > 0 {
                libc::read(master, buf.as_mut_ptr().cast(), buf.len());
            }
        }
    }
    // SAFETY: closing our own descriptors.
    unsafe {
        libc::close(master);
        libc::close(slave);
    }
    let result = fs::read_to_string(services.join("compact/emacs-result")).unwrap_or_default();
    let answer = result
        .split_once(' ')
        .map(|(_, w)| w.trim().to_owned())
        .unwrap_or_default();
    (fs::read_to_string(got).unwrap_or_default(), answer)
}

#[test]
fn relay_parity_compact_from_emacs() {
    let old = std::thread::spawn(|| relay_compacts(false));
    let new = relay_compacts(true);
    assert_eq!(
        new,
        ("/compact".to_owned(), "ok".to_owned()),
        "homund session relay"
    );
    assert_eq!(old.join().unwrap(), new, "compact-relay");
}

/// `homund session rotate` against container/session-rotate on one transcript: the same plan and
/// prompt, and `start` pins a new session whose prompt is that one.
#[test]
fn rotate_parity_plan_and_start() {
    let home = std::env::temp_dir().join(format!("homund-session-{}-rotate", std::process::id()));
    let _ = fs::remove_dir_all(&home);
    let id = "0b6c3f9e-1a2b-4c3d-8e9f-0123456789ab";
    let project = home.join(".claude/projects/p");
    fs::create_dir_all(&project).unwrap();
    let mut text = String::new();
    let entry = |v: Value| v.to_string() + "\n";
    text += &entry(
        serde_json::json!({"type": "user", "turnOrigin": "human", "message": {"content": "before"}}),
    );
    text += &entry(
        serde_json::json!({"type": "user", "isCompactSummary": true, "timestamp": "2026-11-20T10:11:12Z",
        "message": {"content": "the summary"}}),
    );
    for i in 0..60 {
        let said = format!("message {i} {}", "é".repeat(i * 50));
        text += &entry(
            serde_json::json!({"type": "user", "turnOrigin": "human", "timestamp": "2026-11-20T11:00:00Z",
            "message": {"content": said}}),
        );
        text += &entry(
            serde_json::json!({"type": "assistant", "timestamp": "2026-11-20T11:00:01Z",
            "message": {"content": [{"type": "text", "text": format!("answer {i}")}]}}),
        );
        text += &entry(
            serde_json::json!({"type": "user", "turnOrigin": "human", "message": {"content": "<channel>x</channel>"}}),
        );
    }
    let transcript = project.join(format!("{id}.jsonl"));
    fs::write(&transcript, text).unwrap();
    let rotate = checkout().join("container/session-rotate");
    let old = Command::new("python3")
        .arg("-I")
        .arg(&rotate)
        .args(["plan", id, "--threshold-mb", "0.01", "--show"])
        .env("HOME", &home)
        .env_remove("CLAUDE_CONFIG_DIR")
        .output()
        .unwrap();
    let new = Command::new(env!("CARGO_BIN_EXE_homund"))
        .args(["session", "rotate", "plan", id, "threshold", "0.01", "show"])
        .env("HOME", &home)
        .env_remove("CLAUDE_CONFIG_DIR")
        .env_remove("CLAUDE_ROLE")
        .output()
        .unwrap();
    assert!(
        old.status.success(),
        "{}",
        String::from_utf8_lossy(&old.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&new.stdout),
        String::from_utf8_lossy(&old.stdout)
    );

    let marker = home.join("claude/.services/manager");
    fs::create_dir_all(&marker).unwrap();
    fs::write(marker.join("session-rotate"), "0.01\n").unwrap();
    let start = Command::new(env!("CARGO_BIN_EXE_homund"))
        .args(["session", "rotate", "start", id])
        .env("HOME", &home)
        .env_remove("CLAUDE_CONFIG_DIR")
        .env_remove("CLAUDE_ROLE")
        .output()
        .unwrap();
    let fresh = String::from_utf8_lossy(&start.stdout).trim().to_owned();
    assert_eq!(
        fs::read_to_string(home.join(".claude/manager-session")).unwrap(),
        format!("{fresh}\n")
    );
    let seed =
        fs::read_to_string(home.join(format!(".claude/session-rotate/{fresh}.prompt"))).unwrap();
    let shown = String::from_utf8_lossy(&old.stdout)
        .split_once(&"-".repeat(72))
        .unwrap()
        .1
        .trim()
        .to_owned();
    assert_eq!(seed, shown);
}
