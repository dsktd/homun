//! The risk class of a permission request, by fixed rules: tool, input, the cwd and the worktree
//! root to one of `Class`, worst first. A shell command is split at the top-level && || | ; & and
//! newlines, each part's argv judged alone, and the request gets its worst part. Anything the
//! rules cannot see through (command or process substitution, an unquoted redirection) counts
//! as `Writes`. Nothing runs; the only read from disk is the `.git` lookup of `worktree_root`.

use std::path::Path;
use std::path::PathBuf;

use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Class {
    ReadOnly,
    Writes,
    Network,
    Outside,
    Destructive,
}

impl Class {
    pub fn name(self) -> &'static str {
        match self {
            Class::ReadOnly => "read-only",
            Class::Writes => "writes",
            Class::Network => "network",
            Class::Outside => "outside",
            Class::Destructive => "destructive",
        }
    }
}

const READ_ONLY: &[&str] = &[
    "ls", "cat", "head", "tail", "wc", "grep", "rg", "find", "echo", "pwd", "stat", "file", "less",
    "tree", "diff", "which", "du", "df", "jq", "true", "date", "sort", "uniq", "cut", "cd",
];
/// Flags that make a read-only command write or run something.
const WRITE_FLAGS: &[&str] = &[
    "-o", "--output", "-fprint", "-fprint0", "-fprintf", "-fls", "--pre", "-s", "--set",
];
const GIT_READ: &[&str] = &[
    "log",
    "status",
    "diff",
    "show",
    "blame",
    "rev-parse",
    "ls-files",
    "describe",
];
/// Git subcommands that only read when nothing follows but flags.
const GIT_LIST: &[&str] = &["branch", "remote", "tag", "stash"];
const NETWORK: &[&str] = &[
    "curl", "wget", "ssh", "scp", "rsync", "gh", "nc", "ping", "dig",
];
const GIT_NETWORK: &[&str] = &["push", "fetch", "pull", "clone", "ls-remote"];
const DESTROY: &[&str] = &["rm", "rmdir", "shred", "dd", "mkfs", "truncate", "wipefs"];

/// The git toplevel above `cwd`, else `cwd` itself (a session's start dir).
pub fn worktree_root(cwd: &Path) -> PathBuf {
    cwd.ancestors()
        .find(|d| d.join(".git").exists())
        .unwrap_or(cwd)
        .to_path_buf()
}

/// `command` cut at top-level separators into parts, each split into words; None when it
/// holds something the rules cannot judge (substitution, redirection, unbalanced quotes).
fn split(command: &str) -> Option<Vec<Vec<String>>> {
    let (mut parts, mut words, mut word) = (vec![], vec![], String::new());
    let (mut quote, mut chars, mut in_word) = (None, command.chars().peekable(), false);
    while let Some(c) = chars.next() {
        match (quote, c) {
            (Some('\''), '\'') | (Some('"'), '"') => quote = None,
            (Some('"'), '$' | '`') => return None,
            (Some('"'), '\\') => word.extend(chars.next()),
            (Some(_), c) => word.push(c),
            (None, '\'' | '"') => (quote, in_word) = (Some(c), true),
            (None, '\\') => (word.extend(chars.next()), in_word = true).1,
            (None, '$' | '`' | '>' | '<' | '(' | ')') => return None,
            (None, ' ' | '\t') => {
                if std::mem::take(&mut in_word) {
                    words.push(std::mem::take(&mut word));
                }
            }
            (None, '&' | '|' | ';' | '\n') => {
                if chars.peek() == Some(&c) {
                    chars.next();
                }
                if std::mem::take(&mut in_word) {
                    words.push(std::mem::take(&mut word));
                }
                parts.push(std::mem::take(&mut words));
            }
            (None, c) => (word.push(c), in_word = true).1,
        }
    }
    if quote.is_some() {
        return None;
    }
    if in_word {
        words.push(word);
    }
    parts.push(words);
    Some(parts.into_iter().filter(|p| !p.is_empty()).collect())
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
}

/// `path` read from `cwd` made absolute and normalized (no file system access).
fn absolute(
    path: &str,
    cwd: &Path,
) -> PathBuf {
    let joined = match path.strip_prefix('~') {
        Some(rest) => home().join(rest.trim_start_matches('/')),
        None => cwd.join(path),
    };
    let mut out = PathBuf::new();
    for part in joined.components() {
        match part {
            std::path::Component::ParentDir => {
                out.pop();
            }
            std::path::Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}

/// True when the argument `arg`, read from `cwd`, names a path outside `root`.
fn outside(
    arg: &str,
    cwd: &Path,
    root: &Path,
) -> bool {
    let pathy = arg.starts_with('/')
        || arg.starts_with('~')
        || arg.starts_with("..")
        || arg.contains("/..");
    pathy && !arg.starts_with('-') && !absolute(arg, cwd).starts_with(root)
}

fn argv_class(
    argv: &[String],
    cwd: &Path,
    root: &Path,
) -> Class {
    let cmd = argv[0].rsplit('/').next().unwrap_or("");
    let args = &argv[1..];
    let has = |flags: &[&str]| {
        args.iter().any(|a| {
            flags
                .iter()
                .any(|f| a == f || a.starts_with(&format!("{f}=")))
        })
    };
    let positional: Vec<&String> = args.iter().filter(|a| !a.starts_with('-')).collect();
    let sub = positional.first().map(|s| s.as_str());
    let base = if DESTROY.contains(&cmd)
        || (cmd == "find" && has(&["-delete", "-exec", "-execdir", "-ok", "-okdir"]))
    {
        Class::Destructive
    } else if cmd == "git" {
        // `git -C dir` or `git -c k=v` hide the subcommand: judge it as writing
        if args.first().is_some_and(|a| a.starts_with('-')) {
            Class::Writes
        } else if (sub == Some("push") && has(&["-f", "--force", "--force-with-lease"]))
            || (sub == Some("reset") && has(&["--hard"]))
            || sub == Some("clean")
            || (sub == Some("branch") && has(&["-D", "-d", "--delete"]))
        {
            Class::Destructive
        } else if sub.is_some_and(|s| GIT_NETWORK.contains(&s)) {
            Class::Network
        } else if (sub.is_some_and(|s| GIT_READ.contains(&s)) && !has(&["--output", "--ext-diff"]))
            || (sub.is_some_and(|s| GIT_LIST.contains(&s)) && positional.len() == 1)
        {
            Class::ReadOnly
        } else {
            Class::Writes
        }
    } else if NETWORK.contains(&cmd) {
        Class::Network
    } else if READ_ONLY.contains(&cmd)
        && !has(WRITE_FLAGS)
        && !(cmd == "uniq" && positional.len() > 1)
    {
        Class::ReadOnly
    } else {
        Class::Writes
    };
    let out = args.iter().any(|a| outside(a, cwd, root));
    if out { base.max(Class::Outside) } else { base }
}

/// The worst class over the parts of the shell `command`, run in `cwd` inside `root`. A `cd`
/// moves the cwd the later parts are read from.
pub fn command(
    command: &str,
    cwd: &Path,
    root: &Path,
) -> Class {
    let Some(parts) = split(command) else {
        return Class::Writes;
    };
    let mut cwd = cwd.to_path_buf();
    let mut worst = Class::ReadOnly;
    for argv in parts {
        worst = worst.max(argv_class(&argv, &cwd, root));
        if argv[0] == "cd" {
            cwd = absolute(argv.get(1).map_or("~", String::as_str), &cwd);
        }
    }
    worst
}

/// The class of a request for `tool` with `input`.
pub fn classify(
    tool: &str,
    input: &Value,
    cwd: &Path,
    root: &Path,
) -> Class {
    let path = |k: &str| {
        input[k]
            .as_str()
            .is_some_and(|p| !p.is_empty() && !absolute(p, cwd).starts_with(root))
    };
    match tool {
        "Bash" => command(input["command"].as_str().unwrap_or(""), cwd, root),
        "Edit" | "MultiEdit" | "Write" | "NotebookEdit"
            if path("file_path") || path("notebook_path") =>
        {
            Class::Outside
        }
        "Read" | "Grep" | "Glob" if path("file_path") || path("path") => Class::Outside,
        "Read" | "Grep" | "Glob" => Class::ReadOnly,
        "WebFetch" | "WebSearch" => Class::Network,
        _ => Class::Writes,
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use serde_json::json;

    fn class(c: &str) -> &'static str {
        command(c, Path::new("/w/repo"), Path::new("/w/repo")).name()
    }

    #[test]
    fn test_commands() {
        for (c, want) in [
            ("grep -rn TODO src", "read-only"),
            ("git log --oneline -5", "read-only"),
            ("ls | wc -l", "read-only"),
            ("git branch", "read-only"),
            ("git branch new", "writes"),
            ("git commit -m x", "writes"),
            ("git -c core.pager=x log", "writes"),
            ("sed -i s/a/b/ f", "writes"),
            ("echo hi > out.txt", "writes"),
            ("echo hi>out.txt", "writes"),
            ("ls $(rm -rf x)", "writes"),
            ("ls \"`rm x`\"", "writes"),
            ("sort -o f g", "writes"),
            ("uniq a b", "writes"),
            ("rg --pre sh x", "writes"),
            ("env rm x", "writes"),
            ("make", "writes"),
            ("git push origin main", "network"),
            ("curl -s https://x | jq .", "network"),
            ("rm -rf build", "destructive"),
            ("git push --force", "destructive"),
            ("git reset --hard HEAD~1", "destructive"),
            ("find . -name x -delete", "destructive"),
            ("find . -exec rm {} ;", "destructive"),
            ("cat /etc/passwd", "outside"),
            ("cp a ~/Downloads/", "outside"),
            ("cat ../other/f", "outside"),
            ("cat src/../../x", "outside"),
            ("cat /w/repo/src/f", "read-only"),
            ("cd /etc && cat passwd", "outside"),
            ("ls && rm -rf /tmp/x", "destructive"),
            ("ls\nrm x", "destructive"),
            ("echo 'a | rm x'", "read-only"),
            ("echo 'unbalanced", "writes"),
        ] {
            assert_eq!((c, class(c)), (c, want));
        }
    }

    #[test]
    fn test_tools() {
        let (cwd, root) = (Path::new("/w/repo"), Path::new("/w/repo"));
        let c = |tool, input| classify(tool, &input, cwd, root);
        assert_eq!(c("Edit", json!({"file_path": "/w/repo/a"})), Class::Writes);
        assert_eq!(c("Write", json!({"file_path": "/etc/x"})), Class::Outside);
        assert_eq!(c("Read", json!({"file_path": "a"})), Class::ReadOnly);
        assert_eq!(
            c("Read", json!({"file_path": "/etc/shadow"})),
            Class::Outside
        );
        assert_eq!(c("Grep", json!({"pattern": "x"})), Class::ReadOnly);
        assert_eq!(c("WebFetch", json!({})), Class::Network);
        assert_eq!(c("Task", json!({})), Class::Writes);
    }

    #[test]
    fn test_worktree_root() {
        let dir = std::env::temp_dir().join(format!("risk-root-{}", std::process::id()));
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        std::fs::create_dir_all(dir.join("a/b")).unwrap();
        assert_eq!(worktree_root(&dir.join("a/b")), dir);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
