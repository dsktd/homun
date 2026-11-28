#!/bin/sh
# homun doctor (container/homun-doctor) against a made-up ~/claude/.services, a host snapshot and
# a fake claude-services: each area's checks, their status, hint and exit code. The clock is
# fixed, nothing real is read. Run it alone: sh tests/doctor-test.sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d --suffix -homun-doctor-test); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

now=1800000000
s=$tmp/home/claude/.services
mkdir -p "$tmp/bin" "$s/host" "$s/update" "$s/mechanic/reports" "$s/manager" "$s/emacs" "$s/scheduler" "$s/registry/alarm/a" "$s/usage-db"
for n in proxy broken off scheduler report-inbox emacs; do mkdir -p "$s/$n"; printf '#!/bin/sh\n' > "$s/$n/run"; chmod +x "$s/$n/run"; done
echo editor > "$s/emacs/only"; echo 79 > "$s/emacs/pid"
echo PORT=8080 > "$s/proxy/env"
printf 'claude-services: starting 2027-01-15T08:00:00+00:00\nlistening\n' > "$s/proxy/log"
printf 'ok\nTraceback (most recent call last):\nValueError: x\n' > "$s/scheduler/log"
touch "$s/off/disabled"
# The manager's supervisor: emacs is another container's, so its "stopped" here is not believed
cat > "$tmp/bin/claude-services" <<'EOS'
#!/bin/sh
[ "$1" = list ] || exit 2
printf 'broken\t-\tstopped\nemacs\t-\tstopped\noff\t-\tdisabled\nproxy\t8080\trunning 11\nreport-inbox\t-\trunning 12\nscheduler\t8424\trunning 13\n'
EOS
chmod +x "$tmp/bin/claude-services"
touch "$tmp/containerenv"

status() { # status <tick age> <mechanic status> <workspace avail>
	cat > "$s/host/status.json" <<EOS
{"ts":$((now - $1)),"host":{"pid":7,"started":$((now - 7200)),"root":"/x","head":"aaaaaaaaaaaaaaaa","pin":"bbbbbbbbbbbbbbbb","pin_state":"held","pin_why":"uncommitted changes"},
 "containers":[{"role":"manager","name":"claude-manager","status":"running","health":"healthy","image":"1111111111111111","rev":"aaaaaaaaaaaaaaaa","started":$((now - 3600)),"restarts":0,"supervised":0,"stopped":false},
  {"role":"editor","name":"claude-emacs","status":"running","health":"starting","image":"1111111111111111","rev":null,"started":$((now - 60)),"restarts":2,"supervised":0,"stopped":false},
  {"role":"mechanic","name":"claude-mechanic","status":"$2","health":"","image":null,"rev":null,"started":null,"restarts":null,"supervised":3,"stopped":false}],
 "staged":null,"update":"done 1","sync_failed":null,
 "units":[{"unit":"homun-host.service","active":"active"},{"unit":"claude-supervise.timer","active":"active"},{"unit":"homun.service","active":"inactive"}],
 "disk":[{"what":"workspace","path":"/w","avail":$3,"size":1000000000000},{"what":"store","path":"/p","avail":500000000000,"size":1000000000000}]}
EOS
}
status 20 exited 30000000000
echo '{"image":"2222222222222222","built":'$((now - 600))',"rev":"cccccccccccccccc"}' > "$s/update/staged.json"
echo '{"manager":{"current":{"image":"1111111111111111"}}}' > "$s/update/images.json"
echo "failed $((now - 120)) mechanic failed" > "$s/update/state"
echo '{"holder":"mechanic","since":'$((now - 9000))',"scope":"a repair"}' > "$s/mechanic/lease"
touch "$s/mechanic/reports/20270115T080000Z.md"
echo '{"seen":'$((now - 5))'}' > "$s/scheduler/state.json"
printf '* a :sched:\n* b :alarm:\n' > "$s/scheduler/schedule.org"
echo '{"ts":'$((now - 300))',"name":"digest","missed":true}' > "$s/scheduler/history.jsonl"
echo '{}' > "$s/report-inbox/state.json"
printf '{}\n' > "$s/emacs/eval-log.jsonl"; echo '[]' > "$s/emacs/api-schema.json"
stamp() { touch -d "@$(($now - $1))" "$2"; }
stamp 10 "$s/scheduler/log"; stamp 10 "$s/proxy/log"
stamp 30 "$s/manager/heartbeat"; stamp 2400 "$s/mechanic/heartbeat"; stamp 60 "$s/report-inbox/state.json"
stamp 60 "$s/emacs/eval-log.jsonl"; stamp 999999999 "$s/emacs/api-schema.json"

probe='{"pid":79,"version":"31.1","uptime_s":4000,"frames":2,"buffers":30,"errors_1h":3,"last_error":"Error running timer"}'
doctor() {
	env HOME="$tmp/home" CLAUDE_SERVICES_DIR="$s" HOMUN_DOCTOR_NOW=$now CLAUDE_ROLE=manager \
		HOMUN_CONTAINERENV="$tmp/containerenv" PATH="$tmp/bin:$PATH" \
		HOMUN_DOCTOR_COCKPIT="${COCKPIT-$probe}" \
		nu "$here/container/homun-doctor" "$@"
}
rc=0; doctor json > "$tmp/out" 2> "$tmp/err" || rc=$?
[ "$rc" = 1 ] || fail "exit $rc with failing checks: $(cat "$tmp/err")"
is() { # is <id> <status> [<text in the summary or hint>]
	jq -e --arg id "$1" --arg st "$2" --arg t "${3:-}" '.checks[] | select(.id == $id) | select(.status == $st) | select((.summary + " | " + .hint) | contains($t))' "$tmp/out" > /dev/null \
		|| fail "$1 is not $2 with '${3:-}': $(jq -c --arg id "$1" '.checks[] | select(.id == $id)' "$tmp/out")"
}
is container.manager ok "running healthy, image 111111111111 at aaaaaaaaaaaa, up 60 min, 0 restarts"
is container.editor warn "starting"
is container.mechanic fail "homun role start mechanic"
is host.service ok "pid 7, up 2 h, last tick 20 s ago"
is host.pin warn "bbbbbbbbbbbb pinned, aaaaaaaaaaaa checked out: uncommitted changes"
is host.staged warn "222222222222 at cccccccccccc, built 10 min ago, not applied"
is host.update fail "failed 2 min ago: mechanic failed"
is host.units warn "also active: claude-supervise.timer"
is disk.workspace fail "(3%)"
is disk.store ok "(50%)"
ok "containers and host: read from the snapshot, with a hint on every check that is not ok"

is service.proxy ok "running 11, port 8080"
is service.broken fail "claude-services start broken"
is service.off unknown "disabled"
is service.emacs ok "running 79"
is service.scheduler warn "1 error lines in the last 60 of its log: Traceback"
[ "$(jq -r '.checks[] | select(.id == "service.proxy") | .service' "$tmp/out")" = proxy ] || fail "proxy has no restart"
[ "$(jq -r '.checks[] | select(.id == "service.emacs") | .service' "$tmp/out")" = null ] || fail "a service of another container offers a restart"
[ "$(jq -r '.checks[] | select(.id == "service.proxy") | .open' "$tmp/out")" = "$s/proxy/log" ] || fail "proxy does not open its log"
is scheduler.table ok "1 schedules, 1 alarms armed, 1 alarm kinds registered, last pass 5 s ago"
is scheduler.fire warn "digest 5 min ago, missed"
is scheduler.channel ok "beat 30 s ago"
is report-inbox.poll ok "last poll 60 s ago"
ok "services: the supervisor's list, files for another container's, log tail errors, scheduler and report-inbox"

is cockpit.daemon ok "emacs 31.1 pid 79, up 66 min, 2 frames, 30 buffers"
is cockpit.messages warn "3 in the last hour, the last: Error running timer"
is cockpit.eval-log ok "0 rotated, last eval 60 s ago"
is cockpit.schema warn "before the last change of homun-api.el"
is mechanic.heartbeat fail "40 min ago"
is mechanic.report ok "20270115T080000Z.md"
is lease warn "held by mechanic for 2 h: a repair"
is usage-db.sample unknown "no usage.sqlite"
jq -e '.counts.fail >= 4 and .where == "manager" and .snapshot_age == 20' "$tmp/out" > /dev/null || fail "counts: $(jq -c '[.counts, .where, .snapshot_age]' "$tmp/out")"
ok "cockpit, roles and data: the daemon's own answer, the heartbeat, the lease, the caches"

status 4000 exited 30000000000
doctor json > "$tmp/out" 2> "$tmp/err" || true
is container.manager unknown "as of 66 min ago"
is host.service fail "last tick 66 min ago"
rm "$s/host/status.json"; echo '{"ts":'$((now - 10))',"started":'$((now - 100))',"pid":9,"head":"aaaaaaaaaaaaaaaa","pin":"aaaaaaaaaaaaaaaa","pin_state":"current","pin_why":""}' > "$s/host/state.json"
COCKPIT='{"down":"no socket"}' doctor json > "$tmp/out" 2> "$tmp/err" || true
is containers unknown "no host snapshot yet"
is host.service ok "pid 9"
is host.pin ok "aaaaaaaaaaaa checked out"
is cockpit.daemon fail "does not answer: no socket"
is cockpit.messages unknown
[ "$(jq '[.checks[] | select(.id | startswith("disk."))] | length' "$tmp/out")" -ge 1 ] || fail "no disk check without the snapshot"
ok "an old snapshot reads as unknown and a silent host service as failed; without one, state.json stands in"

rc=0; doctor > "$tmp/out" 2> "$tmp/err" || rc=$?
[ "$rc" = 1 ] || fail "the table's exit is $rc"
grep -q "^.*Services" "$tmp/out" && grep -q "broken .*fail .*stopped" "$tmp/out" && grep -q "claude-services start broken" "$tmp/out" && grep -q "ok, .* warn, .* fail, .* unknown" "$tmp/out" || fail "table: $(cat "$tmp/out")"
rm "$s/broken/run" "$s/update/state"; rm -rf "$s/mechanic/heartbeat"
rc=0; COCKPIT='{"pid":1,"version":"31","uptime_s":1,"frames":1,"buffers":1,"errors_1h":0}' doctor > "$tmp/out" 2> "$tmp/err" || rc=$?
[ "$rc" = 0 ] || fail "exit $rc without a failing check: $(grep fail "$tmp/out")"
doctor help | grep -q "usage: homun doctor \[json\]" || fail "no help"
rc=0; doctor nonsense > /dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "an unknown word exits $rc"
ok "the table: areas, hints, the counts line; exit 1 only with a failing check; help"
echo "all passed"
