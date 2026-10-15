# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A launcher that runs one persistent "Manager" Claude Code session in a Podman container named `claude-manager`, driven from a Zellij session of the same name on the host. The container only sees `~/claude`, a treebundel workspace root (`~/claude/.bare/<repo>.git` bare clones, `~/claude/<workspace>/<repo>` worktrees), plus whatever the user mounts in later with `c mount`.

## Commands

- `nix run . -- [flags]` or `nix profile install .` — the `claude-wrapper` launcher, with Nushell, Zellij, xdg-dbus-proxy, just, git and `claude-ns` provided by the flake. Podman and systemd come from the host.
- `./run.nu [flags]` — the same launcher without Nix (needs those tools on PATH). It's a Nushell script (`#!/usr/bin/env nu`), not POSIX shell.
- `just install [name] [dir]` — symlink `run.nu` as `~/.local/bin/c` (by default); an existing non-symlink is moved to `<name>.bak`.
- `just build` / `./run.nu --build` — build the container image (`podman build . -t claude`); `just update` (used by Ctrl+Space U) is the same cached build; `just refresh` rebuilds with `--no-cache` to pick up new Debian packages. Claude Code is not in the image and updates itself.
- `./run.nu -R` — replace the Zellij session (layout changes only apply to new sessions); `--restart-container` also recreates the container so a new image applies. `-s` opens a shell, `-d` only starts the container, `-Z` attaches without Zellij.
- `./run.nu --dryrun` — print the planned disk changes and podman arguments without touching anything.
- Host-only subcommands (they refuse to run inside a container):
  - `c clone <url> [name]` — bare-clone a repo into `~/claude/.bare/<name>.git`.
  - `c mount <path> [--rw]`, `c unmount <path>`, `c mounts` — bind host paths into the running container at the same path (read-only by default), saved in `~/.config/claude/mounts.nuon`.
  - `c port open <host>:<container>[/tcp|/udp] [--from-host]`, `c port close <spec> [--from-host]`, `c ports` — relay ports between host and container localhost, saved in `~/.config/claude/ports.nuon`. Without `--from-host` the host's port reaches the container; with it the container's port reaches the host.

There is no test suite. Validate changes with `--dryrun`, `nu-check run.nu`, the subcommands against fake `podman`/`systemd-run`/`systemctl` scripts on PATH, and `zellij --config zellij/config.kdl setup --check` for the Zellij config.

## Architecture

- **Containerfile / entrypoint.sh** — Debian image with git, gh, nix, notify-send. Tools installed with `nix profile install --profile /nix/var/nix/profiles/default <pkg>` land in the persistent `claude-nix` volume and are on PATH in every container. Claude Code is not in the image: `entrypoint.sh` runs the official installer on first start (under a `flock`, so concurrent starts are safe) into the shared `claude-code`/`claude-code-bin` volumes (`~/.local/share/claude`, `~/.local/bin`), where its own auto-updater maintains it. The container's main process is `claude --continue || claude`.
- **statusline.sh** — the status line also appends throttled usage samples (rate limits, context, cost) to `~/.claude/usage.jsonl` for graphing; per-session throttle state is in `~/.claude/usage/`.
- **run.nu** — starts `claude-manager` in the background if it isn't running, then attaches to its Zellij session.
  - Mounts: `~/claude` rw at the same path; Claude state from `~/.local/share/claude/{claude,claude.json,gh,scratch}` at `~/.claude`, `~/.claude.json`, `~/.config/gh` and `/tmp/claude-0`; the notify proxy socket; the `claude-nix` and `claude-code` volumes. Wrapper config in `~/.config/claude` is never mounted.
  - `plan` only builds podman arguments and the directories/files to create; `prepare` applies them (and seeds `~/claude/CLAUDE.md` from `manager/CLAUDE.md` if missing) only when a container is actually being started, so `--dryrun` stays exact.
  - Right after creating a new container it runs `mounts apply` and `ports apply` so saved mounts and relays come back.
- **manager/CLAUDE.md** — the operating guide for the Manager session, copied to `~/claude/CLAUDE.md` on first start. Edit it here; an existing copy in `~/claude` is never overwritten.
- **lib/** — Nushell modules used by run.nu through their exported commands: `ns.nu` (wraps `podman unshare claude-ns`), `clone.nu`, `mounts.nu`, `ports.nu` (each relay is a transient systemd user unit `claude-port-<in|out>-<proto>-<host>-<container>`).
- **ns/** — `claude-ns`, a Zig helper run under `podman unshare`: `mount`/`unmount` bind mounts into a running container's mount namespace and `relay` TCP/UDP between the host and container network namespaces.
- **zellij/** — host-side Zellij config and layout. `run.nu` sets `CLAUDE_CONTAINER` and puts `bin/` on PATH before starting Zellij, so panes inherit both. The layout's first pane `podman attach`es to Claude; `default_shell` is `bin/claude-container-shell`, so every new pane or tab is a shell inside the container.
  - Ctrl+Space U runs `bin/claude-update` in a floating pane: `just update`, then `run.nu --restart-container --detach` from `~/claude` (via `CLAUDE_WRAPPER_ARGS`/`CLAUDE_WRAPPER_DIR`). It records `running|done|failed <time>` in `CLAUDE_WRAPPER_UPDATING`, which `bin/claude-attach` uses to reattach the claude pane when an update ended its attach.
  - Keybinds are vim-like and modal: Zellij starts in `locked` (insert), `Ctrl Space` enters `tmux` mode as a normal mode, `Esc`/`i` return. They replace Zellij's defaults (`clear-defaults=true`), so every mode used must be bound in full.
- **flake.nix** — packages `run.nu` with its host-side dependencies. Flakes only see git-tracked files: `git add` new files before `nix build`/`nix run`.
