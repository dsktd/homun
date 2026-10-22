#!/usr/bin/env sh
# Supervisor for the Manager's services: every directory under ~/claude/.services
# with an executable `run` is a service. `run` must stay in the foreground; an
# optional `env` (KEY=VALUE lines) is exported before it, a `disabled` marker
# skips it on boot. runit keeps `run` going: `claude-services supervise` (runsvdir,
# started by entrypoint.sh) watches a scan directory (/run/claude-services) holding one
# generated entry per started service, which exports `env`, appends output to `log`
# (emptied before a run when above 10 MB), records the pid in `pid` and restarts a
# crash after 2 s. The service directories stay the source of truth. Installed as
# `claude-services` in the image; entrypoint.sh runs `install-bundled` and `start-all`
# on every container start. Without runit on PATH, start/restart say so and fail.
# CLAUDE_SERVICES_DIR, CLAUDE_SERVICES_BUNDLED, CLAUDE_SERVICES_SCAN and CLAUDE_PROXY_ADMIN (the
# proxy's admin API address, 127.0.0.1:2019) override the defaults; the tests
# set them so they never touch the real services.
#
# The `proxy` service (Caddy) puts every running service with a PORT behind one
# port, at /<name>/. Its Caddyfile is generated here after every start, stop,
# restart and start-all and reloaded through Caddy's admin API when it runs.
# Everything behind it needs HTTP basic auth from `proxy/users` (`user hash`
# lines written by `proxy-password`); without that file it only answers 403.
#
# Services shipped with the wrapper live in `services/` next to this script.
# `install-bundled` copies each into ~/claude/.services/<name> and marks it with
# `.from-wrapper`; a later start refreshes only marked copies (keeping an existing
# `env`, and copying a `disabled` marker on the first install only), so a
# hand-written service of the same name is never touched.
set -u

root=${CLAUDE_SERVICES_DIR:-$HOME/claude/.services}
bundled=${CLAUDE_SERVICES_BUNDLED:-$(dirname "$0")/services}
admin=${CLAUDE_PROXY_ADMIN:-127.0.0.1:2019}
scan=${CLAUDE_SERVICES_SCAN:-/run/claude-services}

usage() {
	echo "usage: claude-services start|stop|restart|logs <name> [lines] | supervise | start-all | list | install-bundled | proxy-config | proxy-password [user]" >&2
	exit 2
}

dir() {
	case $1 in
		*[!A-Za-z0-9_-]* | '') echo "claude-services: bad service name '$1'" >&2; return 1 ;;
	esac
	echo "$root/$1"
}

# Pid of the running `run` process (runit's view), if any. Services in the pause
# after a crash, or stopped, read as not running.
alive() {
	sv status "$scan/$(basename "$1")" 2>/dev/null | sed -n 's/^run: [^(]*(pid \([0-9]*\)).*/\1/p' | grep .
}

# Foreground runsvdir on the scan directory (start backgrounds it). runsvdir
# rescans every 5 s, so a service started for the first time may take that long.
supervise() {
	mkdir -p "$scan" || return 1
	exec runsvdir -P "$scan"
}

# Starts `supervise` in the background unless a runsvdir already watches the scan directory
ensure_supervisor() {
	for c in /proc/[0-9]*/cmdline; do
		[ "$(tr '\0' ' ' <"$c" 2>/dev/null)" = "runsvdir -P $scan " ] && return
	done
	setsid sh "$0" supervise >/dev/null 2>&1 </dev/null &
}

# Scan-directory entry for a service: a `run` that exports env and puts the service in
# its own process group (chpst -P; the pid file holds that group's leader), and a
# `finish` that, after a crash but not a stop, starts `claude-mechanic --notify` detached
# (at most once per 60 s, stamp `.mechanic-stamp` in the services dir) and pauses 2 s before runit restarts it.
# Entries are rewritten on every start, so they follow edits to the service.
entry() {
	e=$scan/$1
	mkdir -p "$e" || return 1
	cat >"$e/run" <<EOF
#!/bin/sh
cd '$2' || exit 1
[ -f log ] && [ "\$(wc -c <log)" -gt 10485760 ] && : >log
exec >>log 2>&1
echo "claude-services: starting \$(date -Is)"
echo \$\$ >pid
set -a; [ -f env ] && . ./env; set +a
exec chpst -P ./run
EOF
	cat >"$e/finish" <<EOF
#!/bin/sh
echo "claude-services: exit \$1 \$(date -Is)" >>'$2/log'
if [ -e '$e/stopping' ]; then :; else
rm -f '$2/pid'
n=\$(date +%s); t=\$(cat '$root/.mechanic-stamp' 2>/dev/null)
if [ \$((n - \${t:-0})) -ge 60 ]; then
echo \$n >'$root/.mechanic-stamp'
setsid claude-mechanic --notify </dev/null >/dev/null 2>&1 &
fi
sleep 2
fi
EOF
	chmod +x "$e/run" "$e/finish"
}

start() {
	d=$(dir "$1") || return 1
	[ -x "$d/run" ] || { echo "claude-services: $1: no executable run script in $d" >&2; return 1; }
	command -v sv >/dev/null && command -v runsvdir >/dev/null && command -v chpst >/dev/null \
		|| { echo "claude-services: runit (sv, runsvdir, chpst) is not on PATH" >&2; return 1; }
	ensure_supervisor
	alive "$d" >/dev/null && return
	entry "$1" "$d" || return 1
	rm -f "${scan:?}/${1:?}/stopping" "$scan/$1/down"
	i=0
	until [ -p "$scan/$1/supervise/ok" ]; do
		i=$((i + 1))
		[ "$i" -le 80 ] || { echo "claude-services: $1: runsv did not appear under $scan in 8 s; is runsvdir running?" >&2; return 1; }
		sleep 0.1
	done
	sv -w 5 up "$scan/$1" >/dev/null || return 1
	# runit calls it up when it forks the wrapper, a moment before the wrapper writes the pid
	i=0
	until [ -s "$d/pid" ] || [ "$i" -ge 20 ]; do i=$((i + 1)); sleep 0.1; done
}

# Stops the service (TERM to its group, KILL to what is left after 5 s), so a restart
# does not race a child for its port
stop() {
	d=$(dir "$1") || return 1
	command -v sv >/dev/null || { echo "claude-services: runit (sv) is not on PATH" >&2; return 1; }
	[ -p "$scan/$1/supervise/ok" ] || return 0
	p=$(cat "$d/pid" 2>/dev/null)
	# down: a restarted runsv keeps it down too
	touch "$scan/$1/stopping" "$scan/$1/down"
	case $p in '' | *[!0-9]*) p= ;; esac
	# runsv only signals the leader: TERM the whole group too, so children shut down cleanly
	sv down "$scan/$1" >/dev/null
	[ -z "$p" ] || kill -s TERM -- -"$p" 2>/dev/null
	sv -w 5 down "$scan/$1" >/dev/null
	[ -z "$p" ] || kill -s KILL -- -"$p" 2>/dev/null
	rm -f "${d:?}/pid"
	return 0
}

# The PORT a service's env sets, if any
port_of() {
	sed -n 's/^PORT=//p' "$1/env" 2>/dev/null | tail -n 1
}

list() {
	for d in "$root"/*/; do
		d=${d%/}
		[ -x "$d/run" ] || continue
		port=$(port_of "$d")
		if p=$(alive "$d"); then state="running $p"
		elif [ -e "$d/disabled" ]; then state=disabled
		else state=stopped
		fi
		printf '%s\t%s\t%s\n' "$(basename "$d")" "${port:--}" "$state"
	done
}

install_bundled() {
	for src in "$bundled"/*/; do
		[ -x "$src/run" ] || continue
		name=$(basename "$src")
		d=$root/$name
		if [ -d "$d" ] && [ ! -e "$d/.from-wrapper" ]; then
			echo "claude-services: $name: not refreshed, $d was not installed by the wrapper" >&2
			continue
		fi
		mkdir -p "$d" || continue
		for f in "$src"/*; do
			# A subdirectory (graphs' provisioning) is replaced whole, so files dropped from the repo go too
			[ -d "$f" ] && { rm -rf "${d:?}/$(basename "$f")"; cp -R "$f" "$d/"; continue; }
			[ -f "$f" ] || continue
			# The installed service's state: a user-edited env is kept (a missing one is
			# copied again), a shipped disabled marker the user removed stays removed
			case $(basename "$f") in
				env) [ -e "$d/env" ] && continue ;;
				disabled) [ -e "$d/.from-wrapper" ] && continue ;;
			esac
			cp -f "$f" "$d/"
		done
		: >"$d/.from-wrapper"
	done
}

# Write $root/proxy/Caddyfile for the running services with a PORT (not the proxy
# itself) and hand it to a running proxy. Nothing happens when no proxy is installed.
proxy_config() {
	pd=$root/proxy
	[ -d "$pd" ] || return 0
	listen=127.0.0.1:$(port_of "$pd")
	[ "$listen" != 127.0.0.1: ] || listen=127.0.0.1:8080
	tls_port=8443
	{
		echo '# Generated by claude-services after every start and stop; edits are overwritten.'
		# grace_period keeps a stop within the supervisor's 2 s wait
		printf '{\n\tadmin %s\n\tauto_https disable_redirects\n\tgrace_period 5s\n}\n\n# Any Host header: a LAN client reaches this through the host port relay. Plain HTTP\n# from anything but loopback is sent to the TLS port, which uses the internal CA of Caddy.\nhttp://:%s, https://:%s {\n\tbind 127.0.0.1\n\ttls internal {\n\t\ton_demand\n\t}\n\t@insecure {\n\t\tprotocol http\n\t\tnot host 127.0.0.1 localhost\n\t}\n\tredir @insecure https://{host}:%s{uri} 308\n' "$admin" "${listen#*:}" "$tls_port" "$tls_port"
		# Only `user bcrypt-hash` lines are accounts; a users file without one is the same as none
		account='^[A-Za-z0-9_.@-]+ \$2[aby]\$'
		if ! grep -Eq "$account" "$pd/users" 2>/dev/null; then
			printf '\trespond "No proxy password is set: run claude-services proxy-password in the Manager container." 403\n}\n'
		else
			printf '\tbasic_auth {\n'
			grep -E "$account" "$pd/users" | while IFS=' ' read -r user hash; do printf '\t\t%s %s\n' "$user" "$hash"; done
			printf '\t}\n'
			index=''
			dash=''
			for d in "$root"/*/; do
				d=${d%/}; name=$(basename "$d")
				[ "$name" != proxy ] && [ -x "$d/run" ] && alive "$d" >/dev/null || continue
				port=$(port_of "$d")
				[ -n "$port" ] || continue
				# Caddy matches paths case-insensitively, so only lowercase names get a route
				case $name in
					*[!a-z0-9_-]*) echo "claude-services: proxy: skipping $name, its name is not lowercase [a-z0-9_-]" >&2; continue ;;
				esac
				case $port in
					*[!0-9]* | '') echo "claude-services: proxy: skipping $name, PORT '$port' is not a number" >&2; continue ;;
				esac
				[ "$port" -ge 1 ] && [ "$port" -le 65535 ] \
					|| { echo "claude-services: proxy: skipping $name, PORT $port is out of range" >&2; continue; }
				# The dashboard owns / (Glance links to absolute paths, so no /dashboard/ prefix)
				if [ "$name" = dashboard ]; then
					dash=$port
					index="$index<li><a href=\"/\">$name</a> <small>127.0.0.1:$port</small></li>"
					continue
				fi
				# A service that serves itself under /<name>/ (a `keep-prefix` marker) gets the path unstripped
				handle=handle_path; [ -e "$d/keep-prefix" ] && handle=handle
				printf '\tredir /%s /%s/\n\t%s /%s/* {\n\t\treverse_proxy 127.0.0.1:%s\n\t}\n' "$name" "$name" "$handle" "$name" "$port"
				index="$index<li><a href=\"/$name/\">$name</a> <small>127.0.0.1:$port</small></li>"
			done
			# The index page is always at /services/, and at / when no dashboard runs
			page=$(printf 'respond `<!doctype html><meta charset="utf-8"><title>Manager services</title><h1>Manager services</h1><ul>%s</ul>` 200' "${index:-<li>no service with a PORT is running</li>}")
			printf '\tredir /services /services/\n\thandle /services/ {\n\t\theader Content-Type "text/html; charset=utf-8"\n\t\t%s\n\t}\n' "$page"
			if [ -n "$dash" ]; then
				printf '\thandle {\n\t\treverse_proxy 127.0.0.1:%s\n\t}\n}\n' "$dash"
			else
				printf '\thandle / {\n\t\theader Content-Type "text/html; charset=utf-8"\n\t\t%s\n\t}\n' "$page"
				printf '\thandle {\n\t\trespond 404\n\t}\n}\n'
			fi
		fi
	} >"$pd/Caddyfile.new" && mv -f "$pd/Caddyfile.new" "$pd/Caddyfile"
	if alive "$pd" >/dev/null; then proxy_reload "$pd"; fi
}

# POST the Caddyfile to a running proxy's admin API, retrying for up to 5 s while
# the proxy loop is alive (right after a start Caddy may not be listening yet)
proxy_reload() {
	i=0
	while :; do
		err=$(curl -sS --fail-with-body -X POST -H 'Content-Type: text/caddyfile' --data-binary "@$1/Caddyfile" \
			"http://$admin/load" 2>&1) && return 0
		i=$((i + 1))
		[ "$i" -lt 25 ] && alive "$1" >/dev/null || break
		sleep 0.2
	done
	echo "claude-services: proxy: reload failed, the Caddyfile on disk applies when the proxy next starts: $err" >&2
	return 1
}

# Set the basic-auth password of a user for the proxy, hashing it with caddy
proxy_password() {
	user=${1:-claude}
	case $user in
		*[!A-Za-z0-9_.@-]* | '') echo "claude-services: bad user name '$user'" >&2; return 1 ;;
	esac
	if [ -t 0 ]; then
		printf 'Password for %s: ' "$user" >&2
		trap 'stty echo' EXIT INT TERM
		stty -echo; IFS= read -r pw; stty echo; echo >&2
		trap - EXIT INT TERM
	else
		IFS= read -r pw
	fi
	[ -n "$pw" ] || { echo 'claude-services: empty password' >&2; return 1; }
	command -v caddy >/dev/null || flock /tmp/claude-nix-profile.lock nix profile install --profile /nix/var/nix/profiles/default nixpkgs#caddy || return 1
	hash=$(printf '%s\n' "$pw" | caddy hash-password) && [ -n "$hash" ] \
		|| { echo 'claude-services: caddy hash-password failed' >&2; return 1; }
	pd=$root/proxy
	mkdir -p "$pd" || return 1
	umask 077
	{ awk -v u="$user" '$1 != u' "$pd/users" 2>/dev/null; echo "$user $hash"; } >"$pd/users.new" \
		&& mv -f "$pd/users.new" "$pd/users" && chmod 600 "$pd/users" || return 1
	proxy_config
}

case ${1:-} in
	# The proxy's own start changes no route, and its admin API is not up yet: no regeneration after it
	start) [ $# -eq 2 ] || usage; proxy_config; start "$2"; rc=$?; [ "$2" = proxy ] || proxy_config; exit $rc ;;
	stop) [ $# -eq 2 ] || usage; stop "$2"; rc=$?; proxy_config; exit $rc ;;
	restart) [ $# -eq 2 ] || usage; stop "$2"; proxy_config; start "$2"; rc=$?; [ "$2" = proxy ] || proxy_config; exit $rc ;;
	# The proxy goes last so its initial Caddyfile already routes to every other service
	start-all)
		rc=0
		for d in "$root"/*/; do
			[ -x "$d/run" ] && [ ! -e "$d/disabled" ] && [ "$(basename "$d")" != proxy ] || continue
			start "$(basename "$d")" || rc=1
		done
		proxy_config
		if [ -x "$root/proxy/run" ] && [ ! -e "$root/proxy/disabled" ]; then start proxy || rc=1; fi
		proxy_config
		exit $rc ;;
	supervise) supervise ;;
	list) list ;;
	logs) [ $# -eq 2 ] || [ $# -eq 3 ] || usage; d=$(dir "$2") || exit 1; tail -n "${3:-50}" "$d/log" ;;
	install-bundled) install_bundled ;;
	proxy-config) proxy_config ;;
	proxy-password) [ $# -le 2 ] || usage; proxy_password "${2:-}" ;;
	*) usage ;;
esac
