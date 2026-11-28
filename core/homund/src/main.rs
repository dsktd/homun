use std::ffi::OsString;
use std::process::ExitCode;

use clap::Parser;
use clap::Subcommand;

#[derive(Parser)]
#[command(
    name = "homund",
    about = "Homun's daemon: the bus, and later the rest of the role side"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// The bus door: send <to> <alarm> <msg> | tail <to> [n] (what homun-msg does)
    #[command(name = "msg")]
    Msg {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<OsString>,
    },

    /// The repair lease: take <holder> <scope> [wait <s>] | release <holder> | show (what homun-lease does)
    #[command(name = "lease")]
    Lease {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },

    /// Work an update would kill, one line each; exit 1 when there is any (what claude-busy does)
    #[command(name = "busy")]
    Busy,

    /// The PermissionRequest hook: hook input on stdin, decision on stdout (what permission-hook.sh does)
    #[command(name = "approve")]
    Approve {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },

    /// The Emacs tools of tools.toml as an MCP server on stdio: mcp [<tools.toml>] | help
    #[command(name = "mcp")]
    Mcp {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },

    /// Where Cal is: beat <focused true|false> <idle_s> | show (desk, mobile or away)
    #[command(name = "presence")]
    Presence {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },

    /// A role's container plan as JSON, with its plan-hash: plan <role> [<checkout>]
    #[command(name = "plan")]
    Plan {
        role: String,
        #[arg(default_value = ".")]
        checkout: std::path::PathBuf,
    },

    /// The user and cal channels as one MCP source: serve | shadow [once] | diff | help
    #[command(name = "channel")]
    Channel {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },

    /// The scheduler: next <cron> <epoch> | fires <table.json> <from> <to> | run shadow|live | diff <real dir> <shadow dir>
    #[command(name = "sched")]
    Sched {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },

    /// A role's session: broker <dir> [args] | relay <cmd> [args] | rotate plan|start ... | recycle <role> [idle [min]]
    #[command(name = "session")]
    Session {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },

    /// The Stage's scene store: store | patch | close | pin | touch | get | list | subscribe | help
    #[command(name = "stage")]
    Stage {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },

    /// Recreate every role on the `claude` image behind its health check, rolling a failed one
    /// back: roll [<checkout>]. One JSON line per role; exits 1 when one is not Healthy
    #[command(name = "roll")]
    Roll {
        #[arg(default_value = ".")]
        checkout: std::path::PathBuf,
    },
}

fn main() -> ExitCode {
    match Cli::parse().command {
        Command::Msg { args } => homund::msg::run(args),
        Command::Lease { args } => homund::lease::run(&args),
        Command::Busy => homund::busy::run(),
        Command::Approve { args } => homund::approve::run(&args),
        Command::Mcp { args } => match homund::mcp::run(&args) {
            Ok(_) => ExitCode::SUCCESS,
            Err(err) => {
                eprintln!("homund mcp: {err}");
                ExitCode::from(2)
            }
        },
        Command::Presence { args } => homund::presence::run(&args),
        Command::Channel { args } => homund::channel::run(&args),
        Command::Sched { args } => homund::sched::run(&args),
        Command::Session { args } => homund::session::run(&args),
        Command::Stage { args } => homund::stage::run(&args),
        Command::Plan { role, checkout } => plan(&role, &checkout),
        Command::Roll { checkout } => roll(&checkout),
    }
}

/// Seconds from the environment (the same knobs as lib/roll.nu), else `fallback`.
fn seconds(
    key: &str,
    fallback: f64,
) -> f64 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(fallback)
}

fn roll(checkout: &std::path::Path) -> ExitCode {
    use homund::roll;
    let run = || -> anyhow::Result<bool> {
        let home = std::path::PathBuf::from(std::env::var("HOME")?);
        let checkout = checkout.canonicalize()?;
        let cfg = std::env::var("HOMUN_CONFIG")
            .map_or_else(|_| home.join(".config/claude/config.json"), Into::into);
        let cfg: serde_json::Value = std::fs::read_to_string(cfg)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        let window = cfg
            .pointer("/update/gate_seconds")
            .and_then(serde_json::Value::as_f64)
            .unwrap_or(180.0);
        let (window, poll) = (
            seconds("HOMUN_GATE_SECONDS", window),
            seconds("HOMUN_GATE_POLL", 5.0),
        );
        let mut exec = roll::Podman {
            checkout: checkout.clone(),
            poll: std::time::Duration::from_secs_f64(poll),
        };
        let roles = exec.roles()?;
        let target = roll::Podman::target()
            .ok_or_else(|| anyhow::anyhow!("there is no image `claude` to roll onto"))?;
        let [file, _] = roll::record_files(&home);
        let record = std::fs::read_to_string(file)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        let rev = std::process::Command::new("git")
            .arg("-C")
            .arg(&checkout)
            .args(["rev-parse", "HEAD"])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map_or("-".into(), |o| {
                String::from_utf8_lossy(&o.stdout).trim().to_owned()
            });
        let polls = if poll > 0.0 {
            (window / poll).ceil() as u32 + 1
        } else {
            window.max(1.0) as u32
        };
        let mut roll = roll::Roll {
            exec: &mut exec,
            record,
            polls: polls.max(roll::PASSES),
            rev,
            now: chrono::Utc::now().timestamp(),
        };
        let out = roll.all(&roles, &target);
        roll::save(&roll.record, &home)?;
        for o in &out {
            println!("{}", serde_json::to_string(o)?);
        }
        Ok(out.iter().all(|o| o.phase == roll::Phase::Healthy))
    };
    match run() {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(err) => {
            eprintln!("homund roll: {err}");
            ExitCode::from(2)
        }
    }
}

fn plan(
    role: &str,
    checkout: &std::path::Path,
) -> ExitCode {
    let spec = homund::plan::Facts::gather(checkout).and_then(|facts| facts.plan(role));
    match spec {
        Ok(spec) => {
            let hash = spec.hash();
            println!("{}", serde_json::json!({ "spec": spec, "hash": hash }));
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("homund plan: {err}");
            ExitCode::FAILURE
        }
    }
}
