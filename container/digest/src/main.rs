//! Print a short live digest of the Manager's work for a SessionStart(compact) hook.

use std::env::var_os;
use std::fs::read_dir;
use std::fs::read_to_string;
use std::path::Path;
use std::path::PathBuf;
use std::process::Command;

use anyhow::Result;
use anyhow::anyhow;

type Section = fn() -> Result<Vec<String>>;

const MAX_LINES: usize = 60;
const SKIP: [&str; 3] = ["_tools", ".services", ".bare"];

fn home() -> Result<PathBuf> {
    var_os("HOME")
        .map(PathBuf::from)
        .ok_or(anyhow!("HOME is not set"))
}

/// Stdout lines of a command, failing on a nonzero exit.
fn lines(cmd: &mut Command) -> Result<Vec<String>> {
    let out = cmd.output()?;
    if !out.status.success() {
        return Err(anyhow!("command failed"));
    }
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::to_owned)
        .collect())
}

/// `gh` with the dsktd token when its file exists, like bin/ghd; the token is never printed.
fn gh(args: &[&str]) -> Result<Vec<String>> {
    let mut cmd = Command::new("gh");
    cmd.args(args);
    let file = match var_os("GHD_TOKEN_FILE") {
        Some(file) => PathBuf::from(file),
        None => home()?.join(".config/gh/dsktd.token"),
    };
    if let Ok(token) = read_to_string(file) {
        cmd.env("GH_TOKEN", token.trim());
    }
    lines(&mut cmd)
}

fn issues() -> Result<Vec<String>> {
    gh(&[
        "issue",
        "list",
        "-R",
        "dsktd/context",
        "--limit",
        "50",
        "--json",
        "number,title,labels",
        "--jq",
        r##".[] | "#\(.number) \(.title) [\(.labels | map(.name) | join(","))]""##,
    ])
}

fn prs() -> Result<Vec<String>> {
    gh(&[
        "pr",
        "list",
        "-R",
        "dsktd/claude-wrapper",
        "--json",
        "number,title,headRefName",
        "--jq",
        r##".[] | "#\(.number) \(.title) (\(.headRefName))""##,
    ])
}

fn branches() -> Result<Vec<String>> {
    let mut found = Vec::new();
    let mut repos: Vec<PathBuf> = read_dir(home()?.join("claude/.bare"))?
        .flatten()
        .map(|entry| entry.path())
        .collect();
    repos.sort();
    for repo in repos {
        let git = |args: &[&str]| lines(Command::new("git").arg("-C").arg(&repo).args(args));
        let Ok(head) = git(&["symbolic-ref", "--short", "HEAD"]) else {
            continue;
        };
        let Some(default) = head.first() else {
            continue;
        };
        let no_merged = format!("--no-merged={default}");
        let Ok(names) = git(&[
            "for-each-ref",
            &no_merged,
            "--format=%(refname:short)",
            "refs/heads",
        ]) else {
            continue;
        };
        let repo_name = repo.file_name().unwrap().to_string_lossy();
        let repo_name = repo_name.trim_end_matches(".git");
        found.extend(names.iter().map(|name| format!("{repo_name}: {name}")));
    }
    Ok(found)
}

fn subdirs(path: &Path) -> Result<Vec<PathBuf>> {
    let mut dirs: Vec<PathBuf> = read_dir(path)?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
        .collect();
    dirs.sort();
    Ok(dirs)
}

fn worktrees() -> Result<Vec<String>> {
    let mut found = Vec::new();
    for workspace in subdirs(&home()?.join("claude"))? {
        let name = workspace.file_name().unwrap().to_string_lossy().into_owned();
        if SKIP.contains(&name.as_str()) {
            continue;
        }
        for repo in subdirs(&workspace)? {
            let repo_name = repo.file_name().unwrap().to_string_lossy();
            found.push(format!("{name}/{repo_name}"));
        }
    }
    Ok(found)
}

fn main() {
    let sections: [(&str, Section); 4] = [
        ("Open issues dsktd/context", issues),
        ("Open PRs dsktd/claude-wrapper", prs),
        ("Unmerged local branches", branches),
        ("Worktrees", worktrees),
    ];
    let mut out = Vec::new();
    for (title, section) in sections {
        out.push(format!("## {title}"));
        match section() {
            Ok(body) if body.is_empty() => out.push("none".into()),
            Ok(body) => out.extend(body),
            Err(_) => out.push(format!("unavailable: {title}")),
        }
    }
    if out.len() > MAX_LINES {
        out.truncate(MAX_LINES - 1);
        out.push("... truncated".into());
    }
    println!("{}", out.join("\n"));
}
