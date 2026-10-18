"""Report-only git hygiene of the bare clones in ~/claude/.bare ($CLAUDE_BARE).

Usage: hygiene.py            one JSON line per repository on stdout
       hygiene.py --summary  one line per repository from hygiene.jsonl

The only change made is `git worktree prune`; worktrees, branches and remotes
are never touched. A repository where git is missing or fails is reported as
{"repo", "error"} and the scan goes on. "merged" is "merged-by-cherry": `git
cherry <default> <branch>` lists no '+' commits, which catches squash merges
only when the patch ids match.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

REPORT = Path(__file__).resolve().parent / "hygiene.jsonl"


def git(path, *args):
    done = subprocess.run(
        ["git", "-C", str(path), *args], capture_output=True, text=True, check=True
    )
    return done.stdout


def merged(repo, default, branch):
    """True when no commit of branch is missing from default by patch id."""
    lines = git(repo, "cherry", default, branch).splitlines()
    return not any(line.startswith("+") for line in lines)


def divergence(repo, base, branch):
    counts = git(repo, "rev-list", "--left-right", "--count", f"{base}...{branch}")
    behind, ahead = counts.split()
    return {"base": base, "ahead": int(ahead), "behind": int(behind)}


def upstreams(repo):
    """{branch: upstream or ""} of the local branches."""
    fmt = "--format=%(refname:short)\t%(upstream:short)"
    out = git(repo, "for-each-ref", fmt, "refs/heads")
    return dict(line.split("\t") for line in out.splitlines())


def worktrees(repo):
    """[(path, branch or None)] of the worktrees, the bare entry left out."""
    found, entry = [], {}
    for line in git(repo, "worktree", "list", "--porcelain").splitlines() + [""]:
        if line:
            key, _, value = line.partition(" ")
            entry[key] = value
        elif entry:
            if "bare" not in entry:
                branch = entry.get("branch", "").removeprefix("refs/heads/")
                found.append((entry["worktree"], branch or None))
            entry = {}
    return found


def inspect(repo):
    git(repo, "worktree", "prune")
    default = git(repo, "symbolic-ref", "--short", "HEAD").strip()
    up = upstreams(repo)
    trees, checked_out = [], set()
    for path, branch in worktrees(repo):
        item = {
            "path": path,
            "branch": branch,
            "dirty": bool(git(path, "status", "--porcelain").strip()),
        }
        if branch:
            checked_out.add(branch)
            item.update(divergence(repo, up.get(branch) or default, branch))
            if branch != default:
                item["merged-by-cherry"] = merged(repo, default, branch)
        trees.append(item)
    others = [b for b in up if b != default and b not in checked_out]
    return {
        "repo": Path(repo).name,
        "default": default,
        "worktrees": trees,
        "branches_without_worktree": [
            {"branch": b, "merged-by-cherry": merged(repo, default, b)} for b in others
        ],
        "branches_without_upstream": [b for b in up if b != default and not up[b]],
    }


def scan(bare):
    for repo in sorted(Path(bare).glob("*.git")):
        try:
            yield inspect(repo)
        except (subprocess.CalledProcessError, OSError) as err:
            detail = getattr(err, "stderr", None) or str(err)
            yield {"repo": repo.name, "error": detail.strip()}


def summary(lines):
    for line in lines:
        r = json.loads(line)
        if "error" in r:
            yield f"{r['repo']}: error: {r['error']}"
            continue
        trees = r["worktrees"]
        yield (
            f"{r['repo']}: {len(trees)} worktrees, "
            f"{sum(t['dirty'] for t in trees)} dirty, "
            f"{sum(t.get('merged-by-cherry', False) for t in trees)} merged, "
            f"{sum(not b['merged-by-cherry'] for b in r['branches_without_worktree'])}"
            " unmerged branches"
        )


def main(argv):
    if argv == ["--summary"]:
        for line in summary(REPORT.read_text().splitlines()):
            print(line)
    elif not argv:
        bare = os.environ.get("CLAUDE_BARE") or Path.home() / "claude/.bare"
        for report in scan(bare):
            print(json.dumps(report))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
