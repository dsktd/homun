# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A launcher that runs Claude Code isolated in a Podman container, one container per project, and drives it from a Zellij session on the host. Only the project directory (plus whatever flags add) is mounted into the container.

## Commands

- `nix run . -- [flags]` or `nix profile install .` — the `claude-wrapper` launcher, with Nushell, Zellij, xdg-dbus-proxy, just and git provided by the flake. Podman and systemd come from the host.
- `./run.nu [flags]` — the same launcher without Nix (needs those tools on PATH). It's a Nushell script (`#!/usr/bin/env nu`), not POSIX shell.
- `just install [name] [dir]` — symlink `run.nu` as `~/.local/bin/c` (by default); an existing non-symlink is moved to `<name>.bak`. Needs Nushell, Zellij etc. on PATH, unlike `nix run`.
- `just build` / `./run.nu --build` — build the container image (`podman build . -t claude`); `just update` (used by Ctrl+Space U) is the same cached build; `just refresh` rebuilds with `--no-cache` to pick up new Debian packages. Claude Code is not in the image and updates itself.
- `./run.nu --host-network` — opt-in host networking so Claude can reach host-local services (e.g. Minecraft MCP mods on localhost); applies when the container starts, so use `--restart-container` for a running one.
- `./run.nu -R` — replace the project's Zellij session (layout changes only apply to new sessions); `--restart-container` also recreates the container so new mounts/image apply.
- `./run.nu --dryrun [flags]` — print the planned disk changes and podman arguments without touching anything.

There is no test suite. Validate changes with `--dryrun` from different directory contexts, `nu-check run.nu`, and `zellij --config zellij/config.kdl setup --check` for the Zellij config.

## Architecture

- **Containerfile / entrypoint.sh** — Debian image with git, gh, nix, notify-send. Tools installed with `nix profile install --profile /nix/var/nix/profiles/default <pkg>` land in the persistent `claude-nix` volume and are on PATH in every container. Claude Code is not in the image: `entrypoint.sh` runs the official installer on first start (under a `flock`, so concurrent starts are safe) into the shared `claude-code`/`claude-code-bin` volumes (`~/.local/share/claude`, `~/.local/bin`), where its own auto-updater maintains it. The container's main process is `claude --continue || claude`.
- **run.nu** — works out what to mount for the current directory, starts the container in the background if it isn't running, then attaches to its Zellij session.
  - `project-info` describes how pwd relates to git and `~/workspaces`: plain directory, git repo/worktree, or treebundel project (a worktree at `~/workspaces/<workspace>/<project>`, which also gets the shared `~/workspaces/.bare` store read-only).
  - `mount-points`, `git-write-mounts` and `claude-state-plan` only *plan*: they return `{src, dst, mode}` mounts plus the directories, files and migrations they need. `prepare` applies those, and only when a container is actually being started. Keep the planners free of disk writes so `--dryrun` stays exact.
  - Mounts always mirror host paths inside the container, so symlinks and recorded paths keep working.
  - Claude state lives under `$XDG_DATA_HOME/claude-wrapper`: `claude/` (shared `~/.claude`), `claude.json`, `gh/`, and per-repo `projects/<group>` (transcripts, memory) and `scratch/<group>` (`/tmp/claude-0`). `-c`/`-C` expose other projects' state read-only/read-write.
- **statusline.sh** — the status line also appends throttled usage samples (rate limits, context, cost) to `~/.claude/usage.jsonl` for graphing; per-session throttle state is in `~/.claude/usage/`.
- **zellij/** — host-side Zellij config and layout. `run.nu` sets `CLAUDE_CONTAINER` and puts `bin/` on PATH before starting Zellij, so panes inherit both. The layout's first pane `podman attach`es to Claude; `default_shell` is `bin/claude-container-shell`, so every new pane or tab is a shell inside the container.
  - Ctrl+Space U runs `bin/claude-update` in a floating pane: `just update`, then `run.nu <original flags> --restart-container --detach` (run.nu passes the flags and project dir in `CLAUDE_WRAPPER_ARGS`/`CLAUDE_WRAPPER_DIR`). It records `running|done|failed <time>` in `CLAUDE_WRAPPER_UPDATING`, which `bin/claude-attach` uses to reattach the claude pane when an update ended its attach.
  - Keybinds are vim-like and modal: Zellij starts in `locked` (insert), `Ctrl Space` enters `tmux` mode as a normal mode, `Esc`/`i` return. They replace Zellij's defaults (`clear-defaults=true`), so every mode used must be bound in full.
- **flake.nix** — packages `run.nu` with its host-side dependencies. Flakes only see git-tracked files: `git add` new files before `nix build`/`nix run`.
