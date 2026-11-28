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
# lines written by `proxy-password`); without that file it only answers 403, unless the
# marker `proxy/open` exists (`proxy-open on`): then there is no login at all, for a LAN
# The user trusts. A login also sets the `claude_session` cookie
# (90 days, secret in `proxy/session-secret`), which then replaces the password;
# `proxy-rotate-session` makes a new secret and so logs every browser out.
# `proxy/hosts` (one hostname or IP per line) fixes the names the TLS certificate covers.
#
# A service directory with an `only` file (one role key, e.g. `editor` for emacs) runs in that role's
# container alone: start-all skips it elsewhere and `start` refuses. Without it: the Manager's.
# Such a service with SOCKET=<file> in its env gets a proxy route to that Unix socket in its
# directory (shared ~/claude), unless it has a `disabled` marker.
# One with an `own-auth` marker authenticates every request itself, so its route skips the proxy login.
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
	echo "usage: claude-services start|stop|restart|logs <name> [lines] | supervise | start-all | list | install-bundled | proxy-config | proxy-password [user] | proxy-rotate-session | proxy-open on|off | route add <path> <port> | route rm <path> | route list | share <name> [for <duration>] [keep] | share <name>|port <n> on test [for <duration>] [force] | share test stop | share tunnel | publish <path> [for <duration>] | unpublish <token> | published | share <name> ticket|stop | share help | shares | send [<path>] [for <duration>] [close grace|confirm|bytes] [force] | send list|help | edge config|acme internal|staging|production|site add <name> <port>|<service> [auth]|site del <name>|site list|help" >&2
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
		# A process can exit between the glob and the read; the redirect's error is the shell's
		[ "$( { tr '\0' ' ' <"$c"; } 2>/dev/null)" = "runsvdir -P $scan " ] && return
	done
	setsid sh "$0" supervise >/dev/null 2>&1 </dev/null &
}

# Scan-directory entry for a service: a `run` that exports env and puts the service in
# its own process group (chpst -P; the pid file holds that group's leader), and a
# `finish` that pauses 2 s before runit restarts a crash, but not after a stop.
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
if [ -e '$e/stopping' ]; then :; else rm -f '$2/pid'; sleep 2; fi
EOF
	chmod +x "$e/run" "$e/finish"
}

# The container a service runs in: its `only` file names a role (CLAUDE_ROLE of that container),
# none means the Manager's
role=${CLAUDE_ROLE:-manager}
here() {
	[ "$(cat "$1/only" 2>/dev/null || echo manager)" = "$role" ]
}

start() {
	d=$(dir "$1") || return 1
	here "$d" || { echo "claude-services: $1: runs in the $(cat "$d/only") container, not this one" >&2; return 1; }
	[ -x "$d/run" ] || { echo "claude-services: $1: no executable run script in $d" >&2; return 1; }
	command -v sv >/dev/null && command -v runsvdir >/dev/null && command -v chpst >/dev/null \
		|| { echo "claude-services: runit (sv, runsvdir, chpst) is not on PATH" >&2; return 1; }
	ensure_supervisor
	alive "$d" >/dev/null && return
	entry "$1" "$d" || { echo "claude-services: $1: could not write its runsv entry" >&2; return 1; }
	rm -f "${scan:?}/${1:?}/stopping" "$scan/$1/down"
	i=0
	until [ -p "$scan/$1/supervise/ok" ]; do
		i=$((i + 1))
		[ "$i" -le 80 ] || { echo "claude-services: $1: runsv did not appear under $scan in 8 s; is runsvdir running?" >&2; return 1; }
		sleep 0.1
	done
	out=$(sv -w 5 up "$scan/$1") || { echo "claude-services: $1: sv up failed: $out" >&2; return 1; }
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
		# A directory without a `run` holds only state written before the first install (the
		# gateway's pair/ and devices/ from a pairing), so it is not the user's own service
		if [ -d "$d" ] && [ ! -e "$d/.from-wrapper" ] && [ -e "$d/run" ]; then
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
	# A wrapper service dropped from the repo: its marked copy would crash on a missing
	# script at every start, so it gets a disabled marker (its log stays). Skipped when
	# nothing is bundled at all (a missing mount must not disable everything).
	ls "$bundled"/*/run >/dev/null 2>&1 || return 0
	for d in "$root"/*/; do
		name=$(basename "$d")
		[ -e "$d/.from-wrapper" ] && [ ! -e "$bundled/$name/run" ] && [ ! -e "$d/disabled" ] || continue
		: >"$d/disabled" && echo "claude-services: $name: no longer shipped with the wrapper, disabled" >&2
	done
	return 0
}

# The proxy's session secret (proxy/session-secret): created once, 32 random bytes in hex
session_secret() {
	sf=$root/proxy/session-secret
	if [ ! -s "$sf" ]; then
		(umask 077; od -An -N32 -tx1 /dev/urandom | tr -d ' \n' >"$sf.new" && mv -f "$sf.new" "$sf") || return 1
	fi
	cat "$sf"
}

# Make a new session secret, which logs every browser out, and reload
proxy_rotate_session() {
	[ -d "$root/proxy" ] || { echo 'claude-services: no proxy service installed' >&2; return 1; }
	rm -f "$root/proxy/session-secret"
	proxy_config
}

# Write $root/proxy/Caddyfile for the running services with a PORT (not the proxy
# itself) and hand it to a running proxy. Nothing happens when no proxy is installed.
proxy_config() {
	# Another container sees only its own runit state: it would write a Caddyfile without the Manager's services
	[ "$role" = manager ] || return 0
	pd=$root/proxy
	[ -d "$pd" ] || return 0
	listen=127.0.0.1:$(port_of "$pd")
	[ "$listen" != 127.0.0.1: ] || listen=127.0.0.1:8080
	tls_port=8443
	# The internal CA's root certificate (public half only) beside the Caddyfile, where the
	# cockpit gateway serves it at /cockpit-gateway/ca.crt and `homun cockpit device add` pins it
	ca=$pd/data/caddy/pki/authorities/local/root.crt
	if [ -f "$ca" ] && ! cmp -s "$ca" "$pd/root.crt"; then cp "$ca" "$pd/root.crt.new" && mv -f "$pd/root.crt.new" "$pd/root.crt"; fi
	# With proxy/hosts (one name or IP per line) the site lists exactly those names and the
	# internal CA issues a certificate for each; a client that dials an IP sends no SNI, so
	# default_sni gives it the first name's certificate, not 127.0.0.1's. Without hosts a
	# certificate is made on demand for whatever name a client asks for
	hosts=$(grep -E '^[A-Za-z0-9._-]+$' "$pd/hosts" 2>/dev/null | grep -vxE '127.0.0.1|localhost')
	if [ -n "$hosts" ]; then
		# TLS only under those names: Caddy picks a certificate by the local address (127.0.0.1
		# behind the relay) before default_sni, and default_sni needs a server without plain HTTP
		sites=$(printf 'https://%s:'"$tls_port"', ' $hosts)
		sites=$(printf '%s {\n\tbind 127.0.0.1\n\ttls internal\n\timport site\n}\n\nhttp://:%s {\n\tbind 127.0.0.1\n\timport site\n}' "${sites%, }" "${listen#*:}")
		sni=$(printf '\tdefault_sni %s' "${hosts%%[[:space:]]*}")
	else
		sni=''
		sites=$(printf 'http://:%s, https://:%s {\n\tbind 127.0.0.1\n\ttls internal {\n\t\ton_demand\n\t}\n\timport site\n}' "${listen#*:}" "$tls_port")
	fi
	{
		echo '# Generated by claude-services after every start and stop; edits are overwritten.'
		# grace_period keeps a stop within the supervisor's 2 s wait
		printf '{\n\tadmin %s\n\tauto_https disable_redirects\n\tgrace_period 5s\n%s\n\torder route after redir\n\t# Only TCP is relayed to the LAN: a browser that switches to HTTP/3 (QUIC, UDP) stalls\n\tservers {\n\t\tprotocols h1 h2\n\t}\n}\n\n# Any Host header: a LAN client reaches this through the host port relay. Plain HTTP\n# from anything but loopback is sent to the TLS port, which uses the internal CA of Caddy.\n(site) {\n\t@insecure {\n\t\tprotocol http\n\t\tnot host 127.0.0.1 localhost\n\t}\n\tredir @insecure https://{host}:%s{uri} 308\n' "$admin" "$sni" "$tls_port"
		# Only `user bcrypt-hash` lines are accounts; a users file without one is the same as none
		account='^[A-Za-z0-9_.@-]+ \$2[aby]\$'
		if [ -e "$pd/open" ]; then
			# proxy/open: no login, the user trusts the LAN (claude-services proxy-open on)
			printf '\t# open: no authentication (proxy/open)\n'
		elif ! grep -Eq "$account" "$pd/users" 2>/dev/null; then
			printf '\trespond "No proxy password is set: run claude-services proxy-password in the Manager container." 403\n}\n'
		else
			# A request carrying the session cookie skips basic_auth; one that passes basic_auth is
			# given the cookie (the header only runs after a successful auth inside the route)
			secret=$(session_secret) || return 1
			# A service with an `own-auth` marker checks every request itself (the cockpit gateway's
			# device keys and pairing codes): its path skips the login. One of another container
			# counts while disabled too: that container enables it (a pairing) without telling this one
			own=''
			for d in "$root"/*/; do
				d=${d%/}; name=$(basename "$d")
				[ -e "$d/own-auth" ] && { [ ! -e "$d/disabled" ] || ! here "$d"; } || continue
				case $name in *[!a-z0-9_-]* | proxy) continue ;; esac
				own="$own /$name/*"
			done
			printf '\t@nosession {\n\t\tnot header Cookie *claude_session=%s*\n' "$secret"
			[ -z "$own" ] || printf '\t\tnot path%s\n' "$own"
			printf '\t}\n\troute {\n\t\tbasic_auth @nosession {\n'
			grep -E "$account" "$pd/users" | while IFS=' ' read -r user hash; do printf '\t\t\t%s %s\n' "$user" "$hash"; done
			printf '\t\t}\n\t\theader @nosession +Set-Cookie "claude_session=%s; Path=/; Max-Age=7776000; HttpOnly; Secure; SameSite=Lax"\n\t}\n' "$secret"
		fi
		if [ -e "$pd/open" ] || grep -Eq "$account" "$pd/users" 2>/dev/null; then
			index=''
			dash=''
			names=' '
			for d in "$root"/*/; do
				d=${d%/}; name=$(basename "$d")
				[ "$name" != proxy ] && [ -x "$d/run" ] || continue
				# A service of another container (an `only` file) with SOCKET=<file in its directory>
				# is reached over that Unix socket on the shared ~/claude, disabled or not: that container
				# enables and starts it (a pairing) without telling this one; a dead socket answers 502
				sock=$(sed -n 's/^SOCKET=//p' "$d/env" 2>/dev/null | tail -n 1)
				if [ -n "$sock" ] && ! here "$d"; then
					case $sock in */* | .* | '') echo "claude-services: proxy: skipping $name, SOCKET must be a file name" >&2; continue ;; esac
					case $name in *[!a-z0-9_-]*) continue ;; esac
					names="$names$name "
					printf '\tredir /%s /%s/\n\thandle_path /%s/* {\n\t\treverse_proxy unix/%s\n\t}\n' "$name" "$name" "$name" "$d/$sock"
					[ -e "$d/hidden" ] || index="$index<li><a href=\"/$name/\">$name</a> <small>unix socket</small></li>"
					continue
				fi
				alive "$d" >/dev/null || continue
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
				names="$names$name "
				# The dashboard owns / (Glance links to absolute paths, so no /dashboard/ prefix)
				if [ "$name" = dashboard ]; then
					dash=$port
					index="$index<li><a href=\"/\">$name</a> <small>127.0.0.1:$port</small></li>"
					continue
				fi
				# A service that serves itself under /<name>/ (a `keep-prefix` marker) gets the path unstripped
				handle=handle_path; [ -e "$d/keep-prefix" ] && handle=handle
				printf '\tredir /%s /%s/\n\t%s /%s/* {\n\t\treverse_proxy 127.0.0.1:%s\n\t}\n' "$name" "$name" "$handle" "$name" "$port"
				# A `hidden` marker keeps the route but leaves the service off the index page
				[ -e "$d/hidden" ] || index="$index<li><a href=\"/$name/\">$name</a> <small>127.0.0.1:$port</small></li>"
			done
			# Routes from `proxy/routes` (`<path> <port>`), longest path first. Caddy matches
			# case-insensitively, so paths are lowercase segments; a service of the same name wins.
			sorted=$(awk 'NF && $1 !~ /^#/ { print length($1), $0 }' "$pd/routes" 2>/dev/null | sort -rn)
			while read -r _ path port extra; do
				[ -n "$path" ] || continue
				case $path in
					*[!a-z0-9/_-]* | /* | */ | *//*) echo "claude-services: proxy: skipping route $path, not lowercase [a-z0-9_-] segments joined by /" >&2; continue ;;
				esac
				case $port$extra in
					*[!0-9]* | '') echo "claude-services: proxy: skipping route $path, '$port${extra:+ $extra}' is not one port" >&2; continue ;;
				esac
				[ "$port" -ge 1 ] && [ "$port" -le 65535 ] \
					|| { echo "claude-services: proxy: skipping route $path, port $port is out of range" >&2; continue; }
				case $names in
					*" $path "*) echo "claude-services: proxy: skipping route $path, a service has that name" >&2; continue ;;
				esac
				printf '\tredir /%s /%s/\n\thandle_path /%s/* {\n\t\treverse_proxy 127.0.0.1:%s\n\t}\n' "$path" "$path" "$path" "$port"
				index="$index<li><a href=\"/$path/\">$path</a> <small>127.0.0.1:$port</small></li>"
			done <<EOR
$sorted
EOR
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
		printf '\n%s\n' "$sites"
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

# proxy-open on|off: the marker proxy/open drops the login entirely (on also removes the
# users file, so a later `off` is a fresh 403 until proxy-password runs again)
proxy_open() {
	pd=$root/proxy
	mkdir -p "$pd" || return 1
	case ${1:-} in
		on) : >"$pd/open" && rm -f "$pd/users" ;;
		off) rm -f "$pd/open" ;;
		*) echo 'usage: claude-services proxy-open on|off' >&2; return 2 ;;
	esac
	proxy_config
}

# route add|rm|list: edit `proxy/routes` atomically, then regenerate the Caddyfile
route() {
	rf=$root/proxy/routes
	case ${1:-} in
		list) [ $# -eq 1 ] && cat "$rf" 2>/dev/null; return 0 ;;
		add) [ $# -eq 3 ] || usage
			case $3 in *[!0-9]* | '') echo "claude-services: bad port '$3'" >&2; return 1 ;; esac ;;
		rm) [ $# -eq 2 ] || usage ;;
		*) usage ;;
	esac
	case $2 in
		*[!a-z0-9/_-]* | /* | */ | *//* | '') echo "claude-services: bad route path '$2'" >&2; return 1 ;;
	esac
	mkdir -p "$root/proxy" || return 1
	{ awk -v p="$2" '$1 != p' "$rf" 2>/dev/null; [ "$1" = add ] && echo "$2 $3"; true; } >"$rf.new" \
		&& mv -f "$rf.new" "$rf" || return 1
	proxy_config
}

# --- Shares: one service's own 127.0.0.1:<PORT> forwarded over dumbpipe (Iroh: encrypted p2p,
# hole punching, relay fallback). State in $root/shares/<name>/ (700, files 600): ticket,
# started, expires, port, README.txt, log; a `keep` marker restarts it on container start.
# runit supervises each as the scan entry `share.<name>` (a dot no service name can hold).
# Both ends run the same pinned nixpkgs, so the dumbpipe/Iroh versions always match.
# The ticket is a bearer secret: it never goes to the log, and dumbpipe's printed secret key
# line is dropped. Without IROH_SECRET every start (and every crash restart) makes a new ticket.
dumbpipe_ref=github:NixOS/nixpkgs/4fe25e12eb9f4c744966dd3de5a05246cf098601#dumbpipe
nixx="nix --extra-experimental-features 'nix-command flakes'"

share_usage() {
	cat >&2 <<'EOF'
usage: claude-services share <name> [for <duration>] [keep]   share a service's own port (default for 24h)
       claude-services share <name> ticket                     print the line for the receiver again
       claude-services share <name> stop                       stop it and forget its ticket
       claude-services shares                                  list: name, port, age, left, state, ticket
       claude-services share <name> on test [for <duration>] [force]
       claude-services share port <n> on test [for <duration>]
                                  map it at https://test.dsktd.net/ (default 1h, at most 24h)
       claude-services share test stop                         end the test mapping
       claude-services share tunnel                            the ticket the relay box's tunnel uses
Durations: <n>m, <n>h or <n>d. keep: start it again after a container recreate (until it expires).
The test host maps one thing at a time (a new one replaces it), never survives a recreate, and
makes it reachable by anyone on the internet with whatever login it has or lacks. The service sees
Host test.dsktd.net and requests at /: services that assume a path prefix or a fixed public URL
may misbehave. design signs in as the user by itself (its autologin marker), so it needs force.
EOF
	exit 2
}

secs() {
	case $1 in
		*[!0-9mhd]* | '' | [mhd]*) return 1 ;;
		*m) echo $((${1%m} * 60)) ;;
		*h) echo $((${1%h} * 3600)) ;;
		*d) echo $((${1%d} * 86400)) ;;
		*) return 1 ;;
	esac
}

# The one line the receiver pastes (bash, zsh, fish and Nushell all take '...' literally)
share_line() {
	echo "$nixx run $dumbpipe_ref -- connect-tcp --addr 127.0.0.1:$(cat "$1/port") $(cat "$1/ticket")"
}

share_print() {
	sd=$root/shares/$1
	i=0
	until [ -s "$sd/ticket" ] || [ "$i" -ge 600 ]; do i=$((i + 1)); sleep 0.1; done
	[ -s "$sd/ticket" ] || { echo "claude-services: share $1: no ticket yet, see $sd/log" >&2; return 1; }
	share_line "$sd"
	echo "then open http://127.0.0.1:$(cat "$sd/port")/"
	share_readme "$1"
}

share_readme() {
	sd=$root/shares/$1
	{
		echo "Run this one line (needs Nix; works without flakes enabled):"
		echo
		share_line "$sd"
		echo
		echo "Then open http://127.0.0.1:$(cat "$sd/port")/ in a browser while it runs."
		echo "If that port is taken on your machine, change both 127.0.0.1:$(cat "$sd/port") to a free port."
		echo "The share ends $(date -d "@$(cat "$sd/expires")" -R) or when stopped."
		echo
		echo "Notes:"
		echo "- The ticket in that line is a password: anyone holding it reaches this service."
		echo "- Some services assume their public URL (Penpot's PENPOT_PUBLIC_URI): links or logins"
		echo "  may point at the original address instead of 127.0.0.1."
		echo "- Without Nix: get dumbpipe 0.39 (cargo install dumbpipe, or a binary from"
		echo "  https://github.com/n0-computer/dumbpipe/releases) and run the part after \`--\`"
		echo "  as: dumbpipe connect-tcp --addr ..."
	} >"$sd/README.txt.new" && mv -f "$sd/README.txt.new" "$sd/README.txt"
}

share_start() {
	d=$(dir "$1") || return 1
	port=$(port_of "$d")
	case $port in *[!0-9]* | '') echo "claude-services: $1 has no PORT to share" >&2; return 1 ;; esac
	sv status "$scan/share.$1" 2>/dev/null | grep -q '^run:' && { echo "claude-services: $1 is already shared; share $1 ticket reprints it" >&2; return 1; }
	sd=$root/shares/$1
	e=$scan/share.$1
	(umask 077; mkdir -p "$root/shares" "$sd") && chmod 700 "$root/shares" "$sd" || return 1
	rm -f "$sd/ticket" "$sd/keep"
	now=$(date +%s)
	(umask 077
		echo "$port" >"$sd/port"; echo "$now" >"$sd/started"; echo $((now + $2)) >"$sd/expires")
	[ "$3" = keep ] && : >"$sd/keep"
	share_entry "$1" || return 1
	echo "Sharing $1 (127.0.0.1:$port) until $(date -d "@$((now + $2))" '+%F %H:%M'). Anyone with the ticket reaches it as you do on"
	echo "loopback, with no login where $1 has none. Stop: claude-services share $1 stop"
	echo
	share_print "$1" || return 1
	echo
	echo "Forwardable instructions: $sd/README.txt"
}

share_entry() {
	sd=$root/shares/$1
	e=$scan/share.$1
	command -v sv >/dev/null && command -v runsvdir >/dev/null || { echo "claude-services: runit is not on PATH" >&2; return 1; }
	ensure_supervisor
	mkdir -p "$e" || return 1
	cat >"$e/run" <<EOF
#!/bin/sh
cd '$sd' || exit 1
umask 077
exec >>log 2>&1
left=\$((\$(cat expires) - \$(date +%s)))
if [ "\$left" -le 0 ]; then
	echo "claude-services: share expired \$(date -Is)"
	rm -f ticket keep README.txt
	touch '$e/down'; sv down '$e'; exit 0
fi
rm -f ticket
echo "claude-services: share starting \$(date -Is), \$left s left"
exec chpst -P sh -c 'timeout "\$0" nix --extra-experimental-features "nix-command flakes" shell $dumbpipe_ref -c dumbpipe listen-tcp --host 127.0.0.1:\$1 2>&1 | while IFS= read -r l; do case \$l in *"secret key"*) ;; "dumbpipe connect-tcp "*) echo "\${l##* }" >ticket.new && mv -f ticket.new ticket && echo "ticket written" ;; *) echo "\$l" ;; esac; done' "\$left" "\$(cat port)"
EOF
	printf '#!/bin/sh\nsleep 2\n' >"$e/finish"
	chmod +x "$e/run" "$e/finish"
	rm -f "$e/down"
	i=0
	until [ -p "$e/supervise/ok" ]; do
		i=$((i + 1)); [ "$i" -le 80 ] || { echo "claude-services: share $1: runsv did not appear" >&2; return 1; }
		sleep 0.1
	done
	sv up "$e" >/dev/null
}

share_stop() {
	e=$scan/share.$1
	if [ -p "$e/supervise/ok" ]; then
		touch "$e/down"; sv -w 5 down "$e" >/dev/null
		p=$(sv status "$e" | sed -n 's/.*(pid \([0-9]*\)).*/\1/p')
		[ -z "$p" ] || kill -s KILL -- -"$p" 2>/dev/null
		# runsvdir drops the runsv of a removed entry
		rm -rf "${e:?}"
	fi
	rm -rf "${root:?}/shares/${1:?}"
}

shares() {
	now=$(date +%s)
	for sd in "$root"/shares/*/; do
		sd=${sd%/}; [ -f "$sd/started" ] || continue
		n=$(basename "$sd")
		state=stopped; sv status "$scan/share.$n" 2>/dev/null | grep -q '^run:' && state=running
		printf '%s\t%s\t%sm\t%sm\t%s\t%s\n' "$n" "$(cat "$sd/port")" $(((now - $(cat "$sd/started")) / 60)) \
			$((($(cat "$sd/expires") - now) / 60)) "$state" "$(cat "$sd/ticket" 2>/dev/null || echo -)"
	done
	# The public edge: the test mapping, published pages, open sends
	python3 -I "$(dirname "$0")/claude-edge" status
	python3 -I "$(dirname "$0")/claude-send" list open
}

# start-all: shares marked keep that have time left
shares_resume() {
	for sd in "$root"/shares/*/; do
		[ -e "$sd/keep" ] || continue
		n=$(basename "$sd")
		[ "$(cat "$sd/expires")" -gt "$(date +%s)" ] && share_entry "$n"
	done
}

share() {
	[ $# -ge 1 ] || share_usage
	[ "$1" = help ] && share_usage
	# The public edge (container/claude-edge): its tunnel ticket and the test host mapping
	[ "$1" = tunnel ] && { [ $# -eq 1 ] || share_usage; exec python3 -I "$(dirname "$0")/claude-edge" tunnel; }
	[ "$1" = port ] || [ "${2:-}" = on ] || { [ "$1" = test ] && [ "${2:-}" = stop ]; } \
		&& exec python3 -I "$(dirname "$0")/claude-edge" share "$@"
	n=$1; shift
	dir "$n" >/dev/null || return 1
	case ${1:-} in
		help) share_usage ;;
		stop) [ $# -eq 1 ] || share_usage; share_stop "$n" ;;
		ticket) [ $# -eq 1 ] || share_usage; [ -d "$root/shares/$n" ] || { echo "claude-services: $n is not shared" >&2; return 1; }; share_print "$n" ;;
		*)
			dur=86400 keep=
			while [ $# -gt 0 ]; do
				case $1 in
					for) [ $# -ge 2 ] && dur=$(secs "$2") || { echo "claude-services: bad duration '${2:-}'" >&2; return 1; }; shift 2 ;;
					keep) keep=keep; shift ;;
					*) share_usage ;;
				esac
			done
			share_start "$n" "$dur" "$keep" ;;
	esac
}

case ${1:-} in
	# The proxy's own start changes no route, and its admin API is not up yet: no regeneration after it
	start) [ $# -eq 2 ] || usage; proxy_config; start "$2"; rc=$?; [ "$2" = proxy ] || proxy_config; exit $rc ;;
	stop) [ $# -eq 2 ] || usage; stop "$2"; rc=$?; proxy_config; exit $rc ;;
	restart) [ $# -eq 2 ] || usage; stop "$2"; proxy_config; start "$2"; rc=$?; [ "$2" = proxy ] || proxy_config; exit $rc ;;
	# The proxy comes right after the scheduler, not last: the rest takes about half a minute, during which
	# it would read as stopped. It starts from the Caddyfile of the last run, which the final proxy_config refreshes.
	start-all)
		rc=0
		t0=$(date +%s)
		# Per-service start time to stdout (entrypoint.sh sends it to start-all.log). The scheduler
		# (Claude's channel MCP server) starts first; the rest wait for Claude's first
		# `role-pin: session` line in start.log or CLAUDE_SERVICES_DELAY seconds (20), so they do not
		# compete with Claude for the CPU while it opens the conversation.
		timed() {
			s=$(date +%s.%N)
			start "$1" || rc=1
			printf '%s %s %.1fs\n' "$(date +%T)" "$1" "$(awk -v a="$s" -v b="$(date +%s.%N)" 'BEGIN { print b - a }')"
		}
		first=
		[ -f "$root/proxy/Caddyfile" ] || proxy_config
		[ -x "$root/proxy/run" ] && [ ! -e "$root/proxy/disabled" ] && here "$root/proxy" && timed proxy
		[ -x "$root/scheduler/run" ] && [ ! -e "$root/scheduler/disabled" ] && here "$root/scheduler" && { timed scheduler; first=scheduler; }
		n=0
		while [ "$n" -lt "${CLAUDE_SERVICES_DELAY:-20}" ] && [ -e "$root/$role/start.log" ] \
			&& ! awk -v t="$t0" '/role-pin: session/ && $1 >= t { f = 1 } END { exit !f }' "$root/$role/start.log"; do
			n=$((n + 1)); sleep 1
		done
		echo "$(date +%T) rest after ${n}s wait"
		for d in "$root"/*/; do
			[ -x "$d/run" ] && [ ! -e "$d/disabled" ] && [ "$(basename "$d")" != proxy ] && [ "$(basename "$d")" != "$first" ] && here "${d%/}" || continue
			timed "$(basename "$d")"
		done
		proxy_config
		shares_resume || rc=1
		echo "$(date +%T) done in $(( $(date +%s) - t0 ))s"
		exit $rc ;;
	supervise) supervise ;;
	list) list ;;
	logs) [ $# -eq 2 ] || [ $# -eq 3 ] || usage; d=$(dir "$2") || exit 1; tail -n "${3:-50}" "$d/log" ;;
	install-bundled) install_bundled ;;
	proxy-config) proxy_config ;;
	proxy-rotate-session) [ $# -eq 1 ] || usage; proxy_rotate_session ;;
	proxy-password) [ $# -le 2 ] || usage; proxy_password "${2:-}" ;;
	proxy-open) [ $# -eq 2 ] || usage; proxy_open "$2" ;;
	route) shift; route "$@" ;;
	share) shift; share "$@" ;;
	shares) [ $# -eq 1 ] || usage; shares ;;
	# One-time file sends through the share host (container/claude-send, the `send` service)
	send) shift; exec python3 -I "$(dirname "$0")/claude-send" "$@" ;;
	# Pages on the page share host (container/claude-edge)
	publish | unpublish | published) exec python3 -I "$(dirname "$0")/claude-edge" "$@" ;;
	# The edge service's own commands: config, tick, acme internal|staging|production
	edge) shift; exec python3 -I "$(dirname "$0")/claude-edge" "$@" ;;
	*) usage ;;
esac
