//! The tracker CLI: each verb is one `emacsclient --eval` form on claude-tracker.el.

use std::env::args;
use std::env::var_os;
use std::io::Read;
use std::io::stdin;
use std::path::Path;
use std::path::PathBuf;
use std::process::Command;
use std::process::exit;

use anyhow::Result;
use anyhow::anyhow;

const HELP: &str = "\
Usage: tracker list [state open|closed|all|KEYWORD] [tag TAG] [repo REPO] [id ID]
       tracker show ID
       tracker add repo REPO title TITLE [body TEXT] [prio a|b|c] [tags T1,T2] [parent ID]
       tracker state ID todo|next|doing|wait|done|drop
       tracker note ID TEXT|-        (- reads the text from stdin)
       tracker set ID PROPERTY VALUE (priority and title set those)
       tracker tag ID add|del TAG
       tracker start ID [repo R]...  (workspace ID-slug under ~/claude with a worktree
                                      per repo, default the issue's project; sets
                                      :WORKSPACE: and DOING; prints the paths)
       tracker done ID               (removes the workspace if every worktree is clean
                                      and merged; sets DONE; never forces)
       tracker archive               (moves DONE/DROP entries closed over 14 days ago
                                      to archive.org beside the file; prints their ids)
       tracker help
Reads print JSON, writes the entry's id. The file is $TRACKER_FILE, default
~/claude/context/tracker.org, through the emacs service's socket.";

/// Repositories whose work happens elsewhere, with the reason `start` gives.
const NO_WORKSPACE: [(&str, &str); 3] = [
    (
        "homun",
        "work happens on main in ~/claude/_tools/homun",
    ),
    (
        "dotfiles",
        "work happens in ~/claude/_tools/dotfiles on nixnixnix",
    ),
    ("treebundel", "the user's own project, hands-off"),
];

fn home() -> Result<PathBuf> {
    var_os("HOME")
        .map(PathBuf::from)
        .ok_or(anyhow!("HOME is not set"))
}

/// An elisp string literal.
fn quote(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        if c == '"' || c == '\\' {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    out
}

fn optional(text: Option<&String>) -> String {
    text.map_or("nil".into(), |text| quote(text))
}

fn id(text: &str) -> Result<String> {
    text.parse::<u64>()
        .map(|id| id.to_string())
        .map_err(|_| anyhow!("Not an id: {text}"))
}

/// `KEY VALUE` pairs from ARGS, each key one of KEYS.
fn pairs(
    args: &[String],
    keys: &[&str],
) -> Result<Vec<(String, String)>> {
    let mut found = Vec::new();
    let mut rest = args;
    while let [key, value, tail @ ..] = rest {
        if !keys.contains(&key.as_str()) {
            return Err(anyhow!("Unknown keyword {key}; one of {}", keys.join(", ")));
        }
        found.push((key.clone(), value.clone()));
        rest = tail;
    }
    if let [key] = rest {
        return Err(anyhow!("{key} needs a value"));
    }
    Ok(found)
}

fn get<'a>(
    pairs: &'a [(String, String)],
    key: &str,
) -> Option<&'a String> {
    pairs.iter().find(|(k, _)| k == key).map(|(_, v)| v)
}

/// The elisp call for ARGS, and whether it reads (prints JSON) or writes (prints an id).
fn form(
    args: &[String],
    file: &str,
) -> Result<(String, bool)> {
    let file = quote(file);
    let strings: Vec<&str> = args.iter().map(String::as_str).collect();
    Ok(match strings.as_slice() {
        ["list", ..] => {
            let pairs = pairs(&args[1..], &["state", "tag", "repo", "id"])?;
            let id = match get(&pairs, "id") {
                Some(text) => id(text)?,
                None => "nil".into(),
            };
            (
                format!(
                    "(claude-tracker-list {file} {} {} {} {id})",
                    optional(get(&pairs, "state")),
                    optional(get(&pairs, "tag")),
                    optional(get(&pairs, "repo")),
                ),
                true,
            )
        }
        ["show", id_] => (format!("(claude-tracker-show {file} {})", id(id_)?), true),
        ["add", ..] => {
            let pairs = pairs(
                &args[1..],
                &["repo", "title", "body", "prio", "tags", "parent"],
            )?;
            let repo = get(&pairs, "repo").ok_or(anyhow!("add needs repo"))?;
            let title = get(&pairs, "title").ok_or(anyhow!("add needs title"))?;
            let tags = match get(&pairs, "tags") {
                Some(tags) => format!(
                    "[{}]",
                    tags.split(',').map(quote).collect::<Vec<_>>().join(" ")
                ),
                None => "nil".into(),
            };
            let parent = match get(&pairs, "parent") {
                Some(text) => id(text)?,
                None => "nil".into(),
            };
            (
                format!(
                    "(claude-tracker-add {file} {} {} {} {} {tags} {parent})",
                    quote(repo),
                    quote(title),
                    optional(get(&pairs, "body")),
                    optional(get(&pairs, "prio")),
                ),
                false,
            )
        }
        ["state", id_, state] => (
            format!(
                "(claude-tracker-state {file} {} {})",
                id(id_)?,
                quote(state)
            ),
            false,
        ),
        ["note", id_, text] => {
            let text = if *text == "-" {
                let mut text = String::new();
                stdin().read_to_string(&mut text)?;
                text.trim_end().to_owned()
            } else {
                (*text).to_owned()
            };
            (
                format!("(claude-tracker-note {file} {} {})", id(id_)?, quote(&text)),
                false,
            )
        }
        ["set", id_, property, value] => (
            format!(
                "(claude-tracker-set {file} {} {} {})",
                id(id_)?,
                quote(property),
                quote(value)
            ),
            false,
        ),
        ["tag", id_, action @ ("add" | "del"), tag] => (
            format!(
                "(claude-tracker-tag {file} {} {} {})",
                id(id_)?,
                quote(action),
                quote(tag)
            ),
            false,
        ),
        ["archive"] => (format!("(claude-tracker-archive {file})"), true),
        _ => return Err(anyhow!("{HELP}")),
    })
}

/// The text of an elisp string literal as emacsclient prints it: `\"`, `\\`,
/// `\n`, `\f` and non-ASCII as octal `\NNN` bytes.
fn unquote(printed: &[u8]) -> String {
    let inner = printed.trim_ascii();
    let inner = inner.strip_prefix(b"\"").unwrap_or(inner);
    let inner = inner.strip_suffix(b"\"").unwrap_or(inner);
    let mut out = Vec::new();
    let mut i = 0;
    while i < inner.len() {
        let c = inner[i];
        i += 1;
        if c != b'\\' || i == inner.len() {
            out.push(c);
            continue;
        }
        let next = inner[i];
        i += 1;
        match next {
            b'n' => out.push(b'\n'),
            b'f' => out.push(b'\x0c'),
            b'0'..=b'7' if i + 1 < inner.len() => {
                let digits = std::str::from_utf8(&inner[i - 1..i + 2]).unwrap();
                out.push(u8::from_str_radix(digits, 8).unwrap());
                i += 2;
            }
            c => out.push(c),
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The printed result of one `emacsclient --eval` of CALL on the tracker.
fn emacs(
    home: &Path,
    call: &str,
    read: bool,
) -> Result<Vec<u8>> {
    let socket = home.join("claude/.services/emacs/socket");
    if !socket.exists() {
        return Err(anyhow!(
            "No emacs socket at {}; start it with claude-services start emacs",
            socket.display()
        ));
    }
    let eval = if read {
        format!("(progn (require 'claude-tracker) (json-serialize {call}))")
    } else {
        format!("(progn (require 'claude-tracker) {call})")
    };
    let out = Command::new("emacsclient")
        .arg("-s")
        .arg(&socket)
        .arg("--eval")
        .arg(eval)
        .output()?;
    if !out.status.success() {
        let stdout = String::from_utf8_lossy(&out.stdout);
        let stderr = String::from_utf8_lossy(&out.stderr);
        return Err(anyhow!("{}", format!("{stdout}{stderr}").trim()));
    }
    Ok(out.stdout)
}

fn git(
    dir: &Path,
    args: &[&str],
) -> Result<String> {
    let out = Command::new("git").arg("-C").arg(dir).args(args).output()?;
    if !out.status.success() {
        return Err(anyhow!(
            "git {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Fetch `origin`; dsktd org clones need the org token's credential helper.
fn fetch(
    home: &Path,
    bare: &Path,
) -> Result<()> {
    let url = git(bare, &["remote", "get-url", "origin"])?;
    let ghd = var_os("TRACKER_GHD")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join("claude/_tools/homun/bin/ghd"));
    if url.trim().starts_with("https://github.com/dsktd/") && ghd.exists() {
        let helper = format!("credential.helper=!{} auth git-credential", ghd.display());
        git(bare, &["-c", "credential.helper=", "-c", &helper, "fetch"])?;
    } else {
        git(bare, &["fetch"])?;
    }
    Ok(())
}

/// The one place that knows the layout: the bare clone and a workspace's worktree.
fn bare_dir(
    home: &Path,
    repo: &str,
) -> PathBuf {
    home.join("claude/.bare").join(format!("{repo}.git"))
}

fn workspace_dir(
    home: &Path,
    ws: &str,
) -> PathBuf {
    home.join("claude").join(ws)
}

fn worktree_dir(
    home: &Path,
    ws: &str,
    repo: &str,
) -> PathBuf {
    workspace_dir(home, ws).join(repo)
}

/// `id-slug`: lowercase words of the title, at most 5 and 40 characters.
fn workspace_name(
    id: &str,
    title: &str,
) -> String {
    let lower = title.to_lowercase();
    let words: Vec<String> = lower
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|w| !w.is_empty())
        .take(5)
        .map(str::to_owned)
        .collect();
    let slug: String = words.join("-").chars().take(40).collect();
    format!("{id}-{}", slug.trim_end_matches('-'))
}

/// The issue's project bare-clone name, title and workspace (empty when unlinked).
fn link(
    home: &Path,
    file: &str,
    id: &str,
) -> Result<(String, String, String)> {
    let out = emacs(
        home,
        &format!("(claude-tracker-link {} {id})", quote(file)),
        false,
    )?;
    let text = unquote(&out);
    let mut lines = text.split('\n');
    let mut next = || lines.next().unwrap_or_default().to_owned();
    Ok((next(), next(), next()))
}

fn default_branch(bare: &Path) -> Result<String> {
    Ok(git(bare, &["symbolic-ref", "--short", "HEAD"])?
        .trim()
        .to_owned())
}

fn start(
    home: &Path,
    file: &str,
    id: &str,
    repos: &[String],
) -> Result<()> {
    let (project, title, linked) = link(home, file, id)?;
    let repos = if repos.is_empty() {
        vec![project]
    } else {
        repos.to_vec()
    };
    for repo in &repos {
        if let Some((_, why)) = NO_WORKSPACE.iter().find(|(name, _)| name == repo) {
            return Err(anyhow!("{repo} has no workspaces: {why}"));
        }
        if !bare_dir(home, repo).is_dir() {
            return Err(anyhow!("No bare clone {}", bare_dir(home, repo).display()));
        }
    }
    let ws = if linked.is_empty() {
        workspace_name(id, &title)
    } else {
        linked
    };
    for repo in &repos {
        let path = worktree_dir(home, &ws, repo);
        if !path.exists() {
            let bare = bare_dir(home, repo);
            fetch(home, &bare)?;
            let base = format!("origin/{}", default_branch(&bare)?);
            git(
                &bare,
                &[
                    "worktree",
                    "add",
                    &path.to_string_lossy(),
                    "-b",
                    &format!("feature/{ws}"),
                    &base,
                ],
            )?;
        }
        println!("{}", path.display());
    }
    emacs(
        home,
        &format!(
            "(claude-tracker-set {} {id} \"WORKSPACE\" {})",
            quote(file),
            quote(&ws)
        ),
        false,
    )?;
    emacs(
        home,
        &format!("(claude-tracker-state {} {id} \"doing\")", quote(file)),
        false,
    )?;
    Ok(())
}

fn finish(
    home: &Path,
    file: &str,
    id: &str,
) -> Result<()> {
    let (_, _, ws) = link(home, file, id)?;
    if ws.is_empty() {
        return Err(anyhow!("#{id} has no workspace"));
    }
    let dir = workspace_dir(home, &ws);
    let mut trees = Vec::new();
    for entry in std::fs::read_dir(&dir)? {
        let path = entry?.path();
        if path.join(".git").exists() {
            trees.push(path);
        }
    }
    for tree in &trees {
        let repo = tree.file_name().unwrap().to_string_lossy();
        if !git(tree, &["status", "--porcelain"])?.is_empty() {
            return Err(anyhow!("{repo} is dirty"));
        }
        let base = format!("origin/{}", default_branch(&bare_dir(home, &repo))?);
        if git(tree, &["cherry", &base, "HEAD"])?
            .lines()
            .any(|l| l.starts_with('+'))
        {
            return Err(anyhow!("{repo} has commits not in {base}"));
        }
    }
    for tree in &trees {
        let repo = tree.file_name().unwrap().to_string_lossy();
        git(
            &bare_dir(home, &repo),
            &["worktree", "remove", &tree.to_string_lossy()],
        )?;
    }
    std::fs::remove_dir(&dir)?;
    emacs(
        home,
        &format!("(claude-tracker-state {} {id} \"done\")", quote(file)),
        false,
    )?;
    Ok(())
}

fn run() -> Result<()> {
    let args: Vec<String> = args().skip(1).collect();
    if args.is_empty() || args[0] == "help" {
        println!("{HELP}");
        return Ok(());
    }
    let home = home()?;
    let file = match var_os("TRACKER_FILE") {
        Some(file) => PathBuf::from(file),
        None => home.join("claude/context/tracker.org"),
    };
    let file = file.to_string_lossy();
    match args
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .as_slice()
    {
        ["start", id_, ..] => {
            let repos = pairs(&args[2..], &["repo"])?;
            return start(
                &home,
                &file,
                &id(id_)?,
                &repos.into_iter().map(|(_, v)| v).collect::<Vec<_>>(),
            );
        }
        ["done", id_] => return finish(&home, &file, &id(id_)?),
        _ => {}
    }
    let (call, read) = form(&args, &file)?;
    let out = emacs(&home, &call, read)?;
    if read {
        println!("{}", unquote(&out));
    } else {
        print!("{}", String::from_utf8_lossy(&out));
    }
    Ok(())
}

fn main() {
    if let Err(err) = run() {
        eprintln!("tracker: {err}");
        exit(1);
    }
}
