#!/usr/bin/env sh

# /opt/homun/shims first: its emacsclient logs every eval, whatever the Nix profiles carry.
export PATH="/opt/homun/shims:$HOME/.local/bin:$PATH"

# Whose container this is, and what its manifest says of it (role-manifest.sh: the m_* values)
role=${CLAUDE_ROLE:-${HOMUN_PRIMARY:-manager}}
here=$(cd "$(dirname "$0")" && pwd)
. "$here/role-manifest.sh"

# Start-up timing, to measure where a start spends its time: `<epoch.ms> <step>` lines in
# ~/claude/.services/<role>/start.log, for a role with `session.boot_record` (start.sh and
# role-pin.sh add theirs). Emptied above 256 KiB. Never fatal: a line that cannot be written is dropped.
tdir=$HOME/claude/.services/$role
mark() {
	[ "$m_boot" = true ] || return 0
	printf '%s %s\n' "$(date +%s.%N | cut -c1-14)" "$1" >>"$tdir/start.log"
	return 0
} 2>/dev/null
if [ "$m_boot" = true ]; then
	(umask 077 && mkdir -p "$tdir") 2>/dev/null
	[ ! -f "$tdir/start.log" ] || [ "$(wc -c <"$tdir/start.log")" -le 262144 ] || (: >"$tdir/start.log") 2>/dev/null
	mark 'entrypoint: start'
fi

flock "$HOME/.local/share/claude/.install.lock" sh -c \
	'command -v claude >/dev/null 2>&1 || curl -fsSL https://claude.ai/install.sh | bash' || exit

# The tools Debian only bootstraps (container/tools/flake.nix: git, gh, jq,
# notify-send, runit, nu, curl) go into the default Nix profile once; PATH puts the
# profile before the image's copies. A failed install rolls back and must not stop
# the boot: the Debian copies keep working. Move an installed one with
# `nix profile upgrade --profile /nix/var/nix/profiles/default tools`.
profile=/nix/var/nix/profiles/default
if [ ! -x "$profile/bin/gh" ]; then
	(
		flock 9 || exit
		gen=$(readlink "$profile" | sed 's/.*-\([0-9]*\)-link$/\1/')
		nix profile install --profile "$profile" path:/opt/homun/tools >/dev/null 2>&1 || {
			nix profile rollback --profile "$profile" --to "$gen" >/dev/null 2>&1
			exit 1
		}
	) 9>/nix/var/claude-nix-profile.lock || echo 'entrypoint: installing container/tools into the Nix profile failed; using the image tools' >&2
fi

# Shims added after the image was built, until the next `just build` puts them in
# the image (the container's own /usr/local/bin is writable and gone on a recreate,
# so this runs on every start).
[ -x /usr/local/bin/claude-job ] || printf '#!/bin/sh\nexec python3 -I /opt/homun/claude-job "$@"\n' > /usr/local/bin/claude-job && chmod 0755 /usr/local/bin/claude-job
[ -x /usr/local/bin/emacsclient ] || printf '#!/bin/sh\nexec sh /opt/homun/emacsclient-shim "$@"\n' > /usr/local/bin/emacsclient && chmod 0755 /usr/local/bin/emacsclient

# gh keeps its extensions in its data dir (~/.local/share/gh), which is not mounted,
# so a recreate would lose them: point it at a directory inside the mounted
# ~/.config/gh instead. An unmounted ~/.config/gh (another role's container) is
# left alone, since nothing there persists either way.
if [ -d "$HOME/.config/gh" ] && [ ! -L "$HOME/.local/share/gh" ]; then
	mkdir -p "$HOME/.config/gh/data" "$HOME/.local/share"
	[ -d "$HOME/.local/share/gh" ] && cp -a "$HOME/.local/share/gh/." "$HOME/.config/gh/data/" && rm -rf "$HOME/.local/share/gh"
	ln -s "$HOME/.config/gh/data" "$HOME/.local/share/gh"
fi

# Shell history: the `homun shell` Nushell keeps it on ~/claude so it survives a recreate
# (~/.config/nushell is in the container's own layer). Shells of other roles share the file.
hist="$HOME/claude/.services/shell"
if mkdir -p "$hist" "$HOME/.config/nushell" 2>/dev/null; then
	h="$HOME/.config/nushell/history.txt"
	[ -f "$h" ] && [ ! -L "$h" ] && cat "$h" >>"$hist/nu-history.txt" && rm -f "$h"
	touch "$hist/nu-history.txt" && ln -sfn "$hist/nu-history.txt" "$h"
fi

# Build output goes under ~/claude/.build, outside the snapshotted tree (the user moves that path to
# its own subvolume). Cargo: intermediates per workspace (no shared build lock), final artifacts
# in one shared dir (target-dir takes no path-hash template). Rewritten on every start; a
# ~/.cargo/config.toml without the marker line is the user's own and is left alone.
cfg="$HOME/.cargo/config.toml"
if [ ! -e "$cfg" ] || head -n1 "$cfg" | grep -q '^# \(claude-wrapper\|homun\) build dirs'; then
	mkdir -p "$HOME/.cargo" "$HOME/claude/.build/cargo" 2>/dev/null && cat >"$cfg" <<EOF
# homun build dirs (rewritten by entrypoint.sh)
[build]
build-dir = "$HOME/claude/.build/cargo/{workspace-path-hash}"
target-dir = "$HOME/claude/.build/cargo/target"
EOF
fi

# The same for the other tools' caches (one KEY=subdir list; the paths are the tools' defaults
# moved under ~/claude/.build/<tool>). Exported here for Claude and its children; shells from
# `podman exec` do not inherit that, so the list is also written as /etc/profile.d/claude-build.sh
# (bash) and a marked ~/.config/nushell/env.nu (Nushell; a file without the marker is left alone).
# Nix's eval cache stays in ~/.cache/nix; CMake/Meson have no global variable.
b="$HOME/claude/.build"
buildenv="SCCACHE_DIR=sccache CCACHE_DIR=ccache GOCACHE=go/build GOMODCACHE=go/mod \
GRADLE_USER_HOME=gradle npm_config_cache=npm YARN_CACHE_FOLDER=yarn PNPM_STORE_DIR=pnpm \
PIP_CACHE_DIR=pip UV_CACHE_DIR=uv ZIG_GLOBAL_CACHE_DIR=zig"
mkdir -p "$b" 2>/dev/null
if [ ! -d "$b/sccache" ] && [ -d "$HOME/claude/.cache/sccache" ]; then
	mv "$HOME/claude/.cache/sccache" "$b/sccache" && rmdir "$HOME/claude/.cache" 2>/dev/null
fi
sh_out="# homun build dirs (rewritten by entrypoint.sh)
"
nu_out="$sh_out"
for kv in $buildenv; do
	k=${kv%%=*}
	d="$b/${kv#*=}"
	export "$k=$d"
	sh_out="${sh_out}export $k=$d
"
	nu_out="${nu_out}\$env.$k = \"$d\"
"
done
printf '%s' "$sh_out" >/etc/profile.d/claude-build.sh 2>/dev/null
nuenv="$HOME/.config/nushell/env.nu"
if [ ! -e "$nuenv" ] || head -n1 "$nuenv" | grep -q '^# \(claude-wrapper\|homun\) build dirs'; then
	mkdir -p "$HOME/.config/nushell" && printf '%s' "$nu_out" >"$nuenv"
fi

# Local-only role identities (names, emoji, colours; ~/claude/.services/identities/roles.json, never in
# the repo) laid over the image's neutral roles.json, which the channel server and Emacs read.
# /opt/homun is read-only, so the merge goes to /dev/shm/homun/roles.json (RAM, never published);
# readers prefer it and fall back to /opt/homun/roles.json.
ids="$HOME/claude/.services/identities/roles.json"
if [ -s "$ids" ] && jq -s '.[0] as $r | .[1] | to_entries | reduce .[] as $e ($r; if has($e.key) then .[$e.key] += ($e.value | {name, emoji, colour} | with_entries(select(.value != null))) else . end)' \
	/opt/homun/roles.json "$ids" >/tmp/roles.merged 2>/dev/null; then
	mkdir -p /dev/shm/homun && cat /tmp/roles.merged >/dev/shm/homun/roles.json && chmod 644 /dev/shm/homun/roles.json
fi
rm -f /tmp/roles.merged
[ -s /dev/shm/homun/roles.json ] && export ROLES_FILE=/dev/shm/homun/roles.json

# Seed the persisted global config (~/.config/git, mounted by run.nu; git uses it
# while ~/.gitconfig is absent) with the gh account as the
# commit identity whenever the global config has no user.name (so on first
# start, or after the user removes it); whatever the user sets stays.
if ! git config --global user.name >/dev/null 2>&1; then
	login=$(gh config get -h github.com user 2>/dev/null) && [ -n "$login" ] && {
		git config --global user.name "$login"
		git config --global user.email "$login@users.noreply.github.com"
	}
fi

# Services under ~/claude/.services (see services.sh): refresh the ones shipped
# with the wrapper, then start every enabled one (the first start also starts runit's runsvdir).
# Only the container of the role with `access.services` runs them: another role's shares
# ~/claude and would start a second copy of each on the same files.
# install-bundled stays in the foreground: start.sh reads what it installs (the scheduler's
# `listen` and channel files). start-all runs in the background, so Claude does not wait for
# every service: nothing Claude needs at its start is a running service (the status line and the
# hooks only read and write files, the scheduler channel is Claude's own MCP server, which
# the scheduler service has always been started ahead of, the Emacs socket is used on demand). Its output goes to
# ~/claude/.services/<role>/start-all.log (the last start only). With the marker
# ~/claude/.services/<role>/start-all-foreground, or when that log cannot be written, it runs
# in the foreground as it always did.
if [ "$m_services" = true ]; then
	(umask 077 && mkdir -p "$tdir") 2>/dev/null
	mark 'entrypoint: tools ready'
	claude-services install-bundled
	mark 'entrypoint: services installed'
	start_all() {
		claude-services start-all || echo 'claude-services: some services failed to start' >&2
		mark 'entrypoint: services started'
	}
	# (a subshell: a failed redirect on `:`, a special builtin, would end this script)
	if [ ! -e "$tdir/start-all-foreground" ] && (: >"$tdir/start-all.log") 2>/dev/null; then
		start_all >"$tdir/start-all.log" 2>&1 </dev/null &
	else
		start_all
	fi
fi

mark 'entrypoint: exec'
exec "$@"
