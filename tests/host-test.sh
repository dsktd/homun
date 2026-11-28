#!/bin/sh
# The host service (bin/homun-host, lib/pin.nu) in a throwaway HOME against tests/fake: each kind
# of request through the spool, the writers inside the
# containers, the supervise tick and the pin. The service runs from a clean clone of this tree,
# so that its checks of the checkout pass and the pin has something to move. Nothing real is
# touched. Run it alone: sh tests/host-test.sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d --suffix -homun-host-test); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# --- a published history like the real one: every publish is one parentless commit ---
mkdir -p "$tmp/src" "$tmp/bin" "$tmp/state" "$tmp/runtime"
(cd "$here" && git ls-files -co --exclude-standard -z | tar --null -T - -cf - 2>/dev/null) | tar -xf - -C "$tmp/src"
git init -q -b main --bare "$tmp/origin.git"
git -C "$tmp/src" init -q -b main
git -C "$tmp/src" remote add origin "$tmp/origin.git"
publish() { # publish <marker>: replace the remote's main with one new parentless commit; prints it
	git -C "$tmp/src" checkout -q --orphan next
	echo "$1" > "$tmp/src/.publish"
	git -C "$tmp/src" add -A
	git -C "$tmp/src" commit -q -m Homun
	git -C "$tmp/src" branch -q -M main
	git -C "$tmp/src" push -q -f origin main
	git -C "$tmp/src" rev-parse HEAD
}
A=$(publish a)
clone=$tmp/clone
git clone -q "$tmp/origin.git" "$clone"

# --- fakes ---
for n in podman pgrep systemctl systemd-run notify-send chafa; do ln -s "$here/tests/fake" "$tmp/bin/$n"; done
cat > "$tmp/bin/zellij" <<'EOS'
#!/bin/sh
echo "zellij $*" >> "$FAKE_LOG"
case "$*" in *list-tabs*) echo '[{"active":true,"viewport_columns":100,"viewport_rows":40}]' ;; esac
EOS
printf '#!/bin/sh\necho "200 100"\n' > "$tmp/bin/identify"
printf '#!/usr/bin/env nu\ndef main [...a] { $"update ($a | str join " ")\\n" | save -a $env.FAKE_LOG }\n' > "$tmp/update"
chmod +x "$tmp/bin/zellij" "$tmp/bin/identify"

home=$tmp/home; s=$home/claude/.services; host=$s/host
mkdir -p "$s/mechanic" "$s/scheduler" "$home/.config/claude" "$home/.config/homun"
run() {
	env HOME="$home" XDG_RUNTIME_DIR="$tmp/runtime" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" \
		HOMUN_CONTAINERENV="$tmp/not-a-container" HOMUN_FLAKE=1 CLAUDE_SERVICES_DIR="$s" \
		DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/bus HOMUN_UPDATE_SCRIPT="$tmp/update" \
		PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/log" FAKE_STATE="$tmp/state" "$@"
}
once() { run nu "$clone/bin/homun-host" once > "$tmp/out" 2>&1 || fail "once: $(cat "$tmp/out")"; }
now() { date +%s; }
ask() { # ask <dir> <id> <json fields after id>
	printf '{"id":"%s",%s}' "$2" "$3" > "$1/.$2.tmp" && mv "$1/.$2.tmp" "$1/$2.json"
}
result() { cat "$host/results/$1.json" 2>/dev/null || echo "(no result for $1)"; }
has() { case "$(result "$1")" in *"$2"*) ;; *) fail "$3: $(result "$1") | $(cat "$tmp/out")" ;; esac; }

# --- the first pass: the spool appears, the supervise tick runs, the state is written ---
: > "$tmp/log"
once
[ -d "$host/requests/cockpit" ] && [ -d "$host/results" ] || fail "no spool after the first pass"
grep -q "podman inspect .*claude-manager" "$tmp/log" || fail "supervise did not look at the manager: $(cat "$tmp/log")"
grep -q '"pin_state":"none"' "$host/state.json" || fail "state: $(cat "$host/state.json")"
grep -q "^update sync" "$tmp/log" && fail "a host without a pin synced by itself"
ok "first pass: spool, supervise tick, state; no sync without a pin"
for k in '"host":{"pid":' '"name":"claude-manager"' '"name":"claude-emacs"' '"units":' '"what":"workspace"' '"staged":'; do
	grep -q "$k" "$host/status.json" || fail "status.json lacks $k: $(cat "$host/status.json" 2>&1)"
done
ok "first pass: the status snapshot names the host service, the containers, the units and the disk"

# --- requests through the spool, one per kind ---
printf '{"rev":"%s","url":"%s"}' "$(git -C "$clone" rev-parse HEAD)" "$tmp/origin.git" > "$home/.config/homun/pin"
ask "$host/requests" r1 "\"kind\":\"restart\",\"from\":\"mechanic\",\"ts\":$(now),\"args\":{\"reason\":\"heartbeat stale\",\"force\":false}"
once
has r1 '"ok":true' "restart was not granted"
has r1 '"text":"granted ok' "restart has no verdict line"
grep -q "granted ok reason=\"heartbeat stale\" by=mechanic" "$s/mechanic/restart.log" || fail "restart.log: $(cat "$s/mechanic/restart.log")"
grep -q "podman run .*--name=claude-manager" "$tmp/log" || fail "the manager's container was not recreated"
ask "$host/requests" r2 "\"kind\":\"restart\",\"from\":\"mechanic\",\"ts\":$(now),\"args\":{\"reason\":\"again\"}"
once
has r2 '"ok":false' "a second restart within 10 minutes was granted"
has r2 'under 600s' "the restart limiter did not answer"
ask "$host/requests" r3 "\"kind\":\"restart\",\"from\":\"mechanic\",\"ts\":$(now),\"args\":{\"reason\":\"\"}"
once
has r3 'reason is empty' "an empty reason passed"
ok "restart: granted, logged, recreated; limiter and validation as before"

ask "$host/requests" o1 "\"kind\":\"role\",\"from\":\"mechanic\",\"ts\":$(now),\"args\":{\"action\":\"retry\",\"role\":\"nosuch\",\"reason\":\"x\"}"
ask "$host/requests" o2 "\"kind\":\"role\",\"from\":\"mechanic\",\"ts\":$(now),\"args\":{\"action\":\"delete\",\"role\":\"editor\",\"reason\":\"x\"}"
ask "$host/requests" o3 "\"kind\":\"role\",\"from\":\"mechanic\",\"ts\":$(($(now) - 900)),\"args\":{\"action\":\"retry\",\"role\":\"editor\",\"reason\":\"x\"}"
once
has o1 'not a role container of this host' "an unknown role passed"
has o2 'action is not retry or rollback' "an unknown action passed"
has o3 's old' "an old role request passed"
grep -q "refused retry nosuch" "$s/mechanic/role-request.log" || fail "role-request.log: $(cat "$s/mechanic/role-request.log")"
ok "role: reaches its script, which refuses and logs as before"

ask "$host/requests" c1 "\"kind\":\"recreate\",\"from\":\"cockpit\",\"ts\":$(now),\"args\":{\"force\":true}"
ask "$host/requests/cockpit" c2 "\"kind\":\"recreate\",\"from\":\"manager\",\"ts\":$(($(now) - 900)),\"args\":{}"
once
has c1 'only taken from the cockpit' "a recreate from the shared spool was taken"
has c2 'stale request' "an old recreate passed"
has c2 '"from":"cockpit"' "the cockpit's part does not set the sender"
ok "recreate: only from the cockpit's part of the spool; age checked"

mkdir -p "$home/claude/img"; printf 'x' > "$home/claude/img/a.png"; printf 'x' > "$tmp/outside.png"
ask "$host/requests" v1 "\"kind\":\"view\",\"from\":\"manager\",\"ts\":$(now),\"args\":{\"path\":\"$home/claude/img/a.png\"}"
ask "$host/requests" v2 "\"kind\":\"view\",\"from\":\"manager\",\"ts\":$(now),\"args\":{\"path\":\"$tmp/outside.png\"}"
once
has v1 '"ok":true' "view failed"
grep -q "zellij --session claude-manager run --floating .*claude-view-draw $home/claude/img/a.png" "$tmp/log" || fail "no pane: $(grep zellij "$tmp/log")"
has v2 'outside ~/claude' "a file outside ~/claude was shown"
ok "view: a pane for a file under ~/claude, refused outside"

ask "$host/requests" p1 "\"kind\":\"report\",\"from\":\"manager\",\"ts\":$(now),\"args\":{\"op\":\"launch\"}"
ask "$host/requests" p2 "\"kind\":\"report\",\"from\":\"manager\",\"ts\":$(now),\"args\":{\"op\":\"file\",\"title\":\"\"}"
once
has p1 'unknown request' "an unknown report op passed"
has p2 'a report needs a title' "a report without a title passed"
ok "report: reaches its script"

ask "$host/requests" s1 "\"kind\":\"sync\",\"from\":\"manager\",\"ts\":$(now),\"args\":{}"
ask "$host/requests" x1 "\"kind\":\"shell\",\"from\":\"manager\",\"ts\":$(now),\"args\":{}"
ask "$host/requests" x2 "\"kind\":\"view\",\"from\":\"Not A Role\",\"ts\":$(now),\"args\":{}"
printf '{"kind": [' > "$host/requests/x3.json"
once
has s1 'pin current' "sync with the pin set"
has x1 'kind is not one of' "an unknown kind passed"
has x2 'from is not a role name' "a bad sender passed"
has x3 'not JSON' "a malformed request passed"
[ -z "$(ls "$host/requests"/*.json 2>/dev/null)" ] || fail "requests left in the spool"
ok "sync with the pin set; unknown kind, bad sender and malformed JSON refused with a result"

run nu "$clone/run.nu" host show > "$tmp/show" 2>&1 || fail "host show: $(cat "$tmp/show")"
grep -q "pin       [0-9a-f]\{12\} checked out" "$tmp/show" && grep -q "sync .*manager .*ok .*pin current" "$tmp/show" && grep -q "restart .*NOT OK .*reason is empty" "$tmp/show" || fail "host show: $(cat "$tmp/show")"
[ "$(sed -n '/^last requests/,/^$/p' "$tmp/show" | grep -c '^  ')" = 10 ] || fail "host show does not list 10 requests: $(cat "$tmp/show")"
ok "host show: service, pin, the last 10 requests, failures"

mkdir -p "$s/proxy" "$s/emacs"; touch "$s/proxy/run" "$s/emacs/run"; echo editor > "$s/emacs/only"
ask "$host/requests/cockpit" s1 "\"kind\":\"service\",\"ts\":$(now),\"args\":{\"action\":\"restart\",\"name\":\"proxy\"}"
ask "$host/requests/cockpit" s2 "\"kind\":\"service\",\"ts\":$(now),\"args\":{\"action\":\"restart\",\"name\":\"emacs\"}"
ask "$host/requests/cockpit" s3 "\"kind\":\"service\",\"ts\":$(now),\"args\":{\"action\":\"restart\",\"name\":\"x; id\"}"
ask "$host/requests/cockpit" s4 "\"kind\":\"service\",\"ts\":$(now),\"args\":{\"action\":\"stop\",\"name\":\"proxy\"}"
ask "$host/requests" s5 "\"kind\":\"service\",\"from\":\"manager\",\"ts\":$(now),\"args\":{\"action\":\"restart\",\"name\":\"proxy\"}"
once
has s1 'restarted proxy' "the service was not restarted"
grep -q "podman exec claude-manager claude-services restart proxy" "$tmp/log" || fail "no restart in the manager's container: $(grep 'podman exec' "$tmp/log")"
has s2 'does not run in the manager' "a service of another container was restarted"
has s3 'not a service name' "a bad service name passed"
has s4 'the only action is restart' "another action passed"
has s5 'only taken from the cockpit' "a service restart from the shared spool was taken"
[ "$(grep -c "claude-services restart" "$tmp/log")" = 1 ] || fail "more than one restart ran"
ok "service: one restart in the manager's container, only from the cockpit, names and action checked"

# --- the writers: the spool when the host service has made it, the old files otherwise ---
req() { run env MECHANIC_DIR="$1/mechanic" CLAUDE_ROLE=mechanic python3 "$here/bin/claude-mechanic-request" restart "why"; }
req "$s"
grep -lq '"kind": *"restart".*"from": *"mechanic".*"reason": *"why"' "$host/requests"/*.json || fail "claude-mechanic-request did not write the spool: $(cat "$host/requests"/*.json)"
rm -f "$host/requests"/*.json
mkdir -p "$tmp/bare/mechanic"; req "$tmp/bare"
grep -q '"reason":"why"' "$tmp/bare/mechanic/restart-request" || fail "claude-mechanic-request without a spool"
run env CLAUDE_VIEW_DIR="$s/view" python3 "$here/container/claude-view" zellij "$home/claude/img/a.png" > /dev/null
grep -lq '"kind": *"view"' "$host/requests"/*.json || fail "claude-view did not write the spool"
rm -f "$host/requests"/*.json
(run env CLAUDE_ROLE=manager python3 "$here/bin/homun-report" show > "$tmp/report" 2>&1 || true) &
n=0; while [ -z "$(ls "$host/requests"/*.json 2>/dev/null)" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
grep -lq '"kind": *"report"' "$host/requests"/*.json || fail "homun-report did not write the spool"
once; wait
[ -s "$tmp/report" ] || fail "homun-report got no answer"
ok "writers: claude-mechanic-request, claude-view and homun-report use the spool, else the old files"

# --- the pin ---
pin() { printf '{"rev":"%s","url":"%s"}' "$1" "${2:-$tmp/origin.git}" > "$home/.config/homun/pin"; }
apply() { run nu -c "use $clone/lib/pin.nu; pin apply $clone ${1:-false} | to json --raw"; }
state() { case "$(apply "${2:-false}")" in *"\"state\":\"$1\""*) ;; *) fail "$3: $(apply "${2:-false}")" ;; esac; }
head() { git -C "$clone" rev-parse HEAD; }

# The case that stranded a clean clone: it sits at an older publish, a fetch has moved origin/main
# on to a later one, and no record names its HEAD. Its HEAD then looks like a local commit to
# `rev-list origin/main..HEAD`.
publish b > /dev/null; git -C "$clone" fetch -q; C=$(publish c)
rm -f "$clone/.git/homun-pin"
[ "$(head)" = "$A" ] && [ -n "$(git -C "$clone" rev-list origin/main..HEAD)" ] && [ ! -e "$clone/.git/homun-pin" ] || fail "the stranded case is not set up"
pin "$C"
state moved false "a clean clone at an older publish was not moved"
[ "$(head)" = "$C" ] && [ "$(cat "$clone/.git/homun-pin")" = "$C" ] || fail "not at the pin"
state current false "a second apply"
ok "pin: a clean clone at an older publish, behind a fetched origin/main, moves to the pin"

D=$(publish d); pin "$D"
echo x > "$clone/.publish"
state held false "uncommitted changes were overwritten"
state held true "force moved over uncommitted changes"
git -C "$clone" checkout -q .publish
touch "$clone/untracked"; state moved false "an untracked file held the clone"; rm "$clone/untracked"
E=$(publish e); pin "$E"
echo y > "$clone/mine"; git -C "$clone" add mine; git -C "$clone" commit -q -m mine
state held false "a local commit was discarded"
git -C "$clone" commit -q --amend -m "mine, amended"
state held false "an amended commit was discarded"
state moved true "force did not move over local commits"
pin 0123456789012345678901234567890123456789
state failed false "a commit that cannot be fetched"
[ "$(head)" = "$E" ] || fail "the clone moved off $E"
pin "$E" https://example.invalid/other.git
F=$(publish f); pin "$F" https://example.invalid/other.git
state held false "a checkout of another origin was moved"
ok "pin: uncommitted changes, local and amended commits and another origin hold; force; an unknown commit fails"

# The service follows the pin itself, starts no sync for a failed commit, and syncs once otherwise
pin "$F"; : > "$tmp/log"
once
[ "$(head)" = "$F" ] || fail "the service did not follow the pin: $(cat "$tmp/out")"
grep -q "pin moved" "$tmp/out" || fail "the move is not in the log: $(cat "$tmp/out")"
grep -q "^update sync" "$tmp/log" && fail "synced from the old code instead of starting again first"
once
n=0; while ! grep -q "^update sync" "$tmp/log" && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
grep -q "^update sync" "$tmp/log" || fail "no sync after the move: $(cat "$tmp/out")"
grep -q "\"pin_state\":\"current\"" "$host/state.json" || fail "state: $(cat "$host/state.json")"
printf '%s 1\n' "$F" > "$home/.config/claude/sync-failed"; : > "$tmp/log"
once; sleep 0.5
grep -q "^update sync" "$tmp/log" && fail "a failed commit was synced again by itself"
grep -q "failed before" "$tmp/out" || fail "the failed sync is not said: $(cat "$tmp/out")"
run nu "$clone/run.nu" host sync > "$tmp/out" 2>&1 || fail "host sync: $(cat "$tmp/out")"
grep -q "^update sync" "$tmp/log" && [ ! -e "$home/.config/claude/sync-failed" ] || fail "host sync did not retry"
echo running "$(now)" > "$s/update/state"; G=$(publish g); pin "$G"
once
[ "$(head)" = "$F" ] || fail "the checkout was moved under a running update"
rm "$s/update/state"; once
[ "$(head)" = "$G" ] || fail "the pin was not followed once the update ended"
ok "service: follows the pin, syncs once after starting again, not a failed commit; host sync retries; waits for a running update"

# --- the loop itself: it follows a new pin, starts again from the new code and keeps answering ---
H=$(publish h); pin "$H"; : > "$tmp/log"
run nu "$clone/run.nu" host run > "$tmp/loop" 2>&1 &
loop=$!
n=0; while ! grep -q "^update sync" "$tmp/log" && [ "$n" -lt 150 ]; do sleep 0.1; n=$((n + 1)); done
ask "$host/requests" l1 "\"kind\":\"sync\",\"from\":\"manager\",\"ts\":$(now),\"args\":{}"
n=0; while ! grep -q '"state":"done"' "$host/results/l1.json" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
kill "$loop" 2>/dev/null; wait "$loop" 2>/dev/null || true
[ "$(head)" = "$H" ] || fail "the loop did not follow the pin: $(cat "$tmp/loop")"
[ "$(grep -c "host: started from" "$tmp/loop")" = 2 ] || fail "the loop did not start again after the move: $(cat "$tmp/loop")"
grep -q "systemctl --user disable --now claude-supervise.timer" "$tmp/log" || fail "the replaced units were not stopped"
has l1 'pin current' "the loop did not answer a request within 5 s"
ok "loop: stops the replaced units, follows the pin, starts again from the new code, answers within seconds"

# --- homund roll: an injected failure rolls back (core/homund/src/roll.rs, against fakes) ---
# A launcher whose restart puts a role on $HOMUN_IMAGE, and a podman whose health check fails on
# the image "bad": the manager must go back to "good" and the roll stop before the mechanic.
r=$tmp/roll; mkdir -p "$r/co" "$r/bin" "$r/st" "$r/home/.config/claude"
cat > "$r/co/run.nu" <<'EOS'
def main [...a] {
    if $a.1 == roles { print "manager claude-manager\nmechanic claude-mechanic"; return }
    $"($a.3)\n" | save -a ($env.FAKE_STATE | path join restarts)
    $"running id-($a.3)-(random int) ($env.HOMUN_IMAGE)" | save -f ($env.FAKE_STATE | path join $"claude-($a.3)")
}
EOS
cat > "$r/bin/podman" <<'EOS'
#!/bin/sh
for last; do :; done
case "$1 $2" in
	"image inspect") echo bad ;;
	"image exists") [ "$last" = good ] ;;
	"healthcheck run") ! grep -q ' bad$' "$FAKE_STATE/$last" ;;
	inspect*) cat "$FAKE_STATE/$last" 2>/dev/null || exit 125 ;;
esac
EOS
chmod +x "$r/bin/podman"
for c in manager mechanic; do echo "running id-$c good" > "$r/st/claude-$c"; done
echo '{"manager":{"current":{"image":"good","rev":"a","time":1,"good":true}},"mechanic":{"current":{"image":"good","rev":"a","time":1,"good":true}}}' > "$r/home/.config/claude/images.json"
homund=${HOMUND:-$(cargo build -q --manifest-path "$here/core/homund/Cargo.toml" --message-format=json 2>/dev/null | sed -n 's/.*"executable":"\([^"]*homund\)".*/\1/p' | tail -n 1)}
[ -x "$homund" ] || fail "no homund binary (set HOMUND, or have cargo)"
env HOME="$r/home" PATH="$r/bin:$PATH" FAKE_STATE="$r/st" HOMUN_GATE_SECONDS=2 HOMUN_GATE_POLL=0 \
	"$homund" roll "$r/co" > "$r/out" 2>&1 && fail "a failed roll exited 0: $(cat "$r/out")"
grep -q '"role":"manager","phase":"RolledBack"' "$r/out" || fail "the manager was not rolled back: $(cat "$r/out")"
[ "$(cat "$r/st/restarts")" = "manager
manager" ] || fail "restarts: $(cat "$r/st/restarts")"
grep -q ' good$' "$r/st/claude-manager" || fail "the manager is not on its good image"
grep -q '"manager":{"current":{"image":"good"' "$r/home/.config/claude/images.json" || fail "record: $(cat "$r/home/.config/claude/images.json")"
ok "homund roll: a manager failing its health check goes back to its previous image; the mechanic is not touched"

echo "all passed"
