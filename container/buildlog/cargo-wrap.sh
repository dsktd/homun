# cargo-wrap.sh: source from a devShell shellHook (bash or zsh). Defines `cargo`, which tees
# build, run, test, check and clippy output to $BUILDLOG_ROOT/<project>/<UTC>.log (default
# ~/claude/.services/buildlog), keeps the 20 newest and writes latest.json (project, command,
# exit code, where, seconds, log). Output, colours and exit code stay as without the wrapper.
# The buildlog-watch service alarms the manager on a failing latest.json. Linux only.
cargo() {
	case ${1:-} in
	build | b | run | r | test | t | check | c | clippy) ;;
	*) command cargo "$@"; return ;;
	esac
	local root=${BUILDLOG_ROOT:-$HOME/claude/.services/buildlog}
	local proj=${BUILDLOG_PROJECT:-$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")}
	local dir=$root/$proj log where=host start rc
	mkdir -p "$dir" 2>/dev/null || { command cargo "$@"; return; }
	[ -e /run/.containerenv ] && where=container
	log=$dir/$(date -u +%Y%m%dT%H%M%SZ).log
	start=$(date +%s.%N)
	if [ -t 1 ]; then
		CARGO_TERM_COLOR=${CARGO_TERM_COLOR:-always} command cargo "$@" 2>&1 | tee "$log"
	else
		command cargo "$@" 2>&1 | tee "$log"
	fi
	rc=${pipestatus[1]:-${PIPESTATUS[0]}}
	printf '{"project":"%s","command":"cargo %s","exit":%d,"where":"%s","seconds":%s,"log":"%s"}\n' \
		"$proj" "$*" "$rc" "$where" "$(awk "BEGIN{print $(date +%s.%N) - $start}")" "$log" \
		>"$dir/latest.json.tmp" && mv "$dir/latest.json.tmp" "$dir/latest.json"
	ls -1t "$dir"/*.log 2>/dev/null | tail -n +21 | xargs -r rm -f
	return "$rc"
}
