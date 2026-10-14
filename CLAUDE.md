# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A launcher that runs Claude Code isolated in a Podman container, one container per project, and drives it from a Zellij session on the host. Only the project directory (plus whatever flags add) is mounted into the container.

## Commands

- `nix run . -- [flags]` or `nix profile install .` — the `claude-wrapper` launcher, with Nushell, Zellij, xdg-dbus-proxy, just and git provided by the flake. Podman and systemd come from the host.
- `./run.nu [flags]` — the same launcher without Nix (needs those tools on PATH). It's a Nushell script (`#!/usr/bin/env nu`), not POSIX shell.
- `just install [name] [dir]` — symlink `run.nu` as `~/.local/bin/c` (by default); an existing non-symlink is moved to `<name>.bak`. Needs Nushell, Zellij etc. on PATH, unlike `nix run`.
- `just build` / `./run.nu --build` — build the container image (`podman build . -t claude`); `just update` also busts the Claude Code install layer.
- `./run.nu --dryrun [flags]` — print the planned disk changes and podman arguments without touching anything.

There is no test suite. Validate changes with `--dryrun` from different directory contexts, `nu-check run.nu`, and `zellij --config zellij/config.kdl setup --check` for the Zellij config.

## Architecture

- **Containerfile / entrypoint.sh** — Debian image with Claude Code (official installer), git, gh, nix, notify-send. The container's main process is `claude --continue || claude`.
- **run.nu** — works out what to mount for the current directory, starts the container in the background if it isn't running, then attaches to its Zellij session.
  - `project-info` describes how pwd relates to git and `~/workspaces`: plain directory, git repo/worktree, or treebundel project (a worktree at `~/workspaces/<workspace>/<project>`, which also gets the shared `~/workspaces/.bare` store read-only).
  - `mount-points`, `git-write-mounts` and `claude-state-plan` only *plan*: they return `{src, dst, mode}` mounts plus the directories, files and migrations they need. `prepare` applies those, and only when a container is actually being started. Keep the planners free of disk writes so `--dryrun` stays exact.
  - Mounts always mirror host paths inside the container, so symlinks and recorded paths keep working.
  - Claude state lives under `$XDG_DATA_HOME/claude-wrapper`: `claude/` (shared `~/.claude`), `claude.json`, `gh/`, and per-repo `projects/<group>` (transcripts, memory) and `scratch/<group>` (`/tmp/claude-0`). `-c`/`-C` expose other projects' state read-only/read-write.
- **zellij/** — host-side Zellij config and layout. `run.nu` sets `CLAUDE_CONTAINER` and puts `bin/` on PATH before starting Zellij, so panes inherit both. The layout's first pane `podman attach`es to Claude; `default_shell` is `bin/claude-container-shell`, so every new pane or tab is a shell inside the container.
  - Keybinds are vim-like and modal: Zellij starts in `locked` (insert), `Ctrl Space` enters `tmux` mode as a normal mode, `Esc`/`i` return. They replace Zellij's defaults (`clear-defaults=true`), so every mode used must be bound in full.
- **flake.nix** — packages `run.nu` with its host-side dependencies. Flakes only see git-tracked files: `git add` new files before `nix build`/`nix run`.
