#!/bin/sh
# CLI parsing of bin/homun-emacs against a fake emacsclient.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home/claude/.services/emacs" "$tmp/bin"
: > "$tmp/home/claude/.services/emacs/socket"
cat > "$tmp/bin/emacsclient" <<'EOS'
#!/bin/sh
echo "$@" >> "$FAKE_LOG"
printf '%s\n' "$FAKE_REPLY"
EOS
chmod +x "$tmp/bin/emacsclient"
run() { reply=$1; shift; HOME="$tmp/home" PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/log" FAKE_REPLY="$reply" nu "$here/bin/homun-emacs" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

out=$(run '"ok\nline \"q\" \\ x"' slate insert text hi) || fail ok
[ "$(printf '%s' "$out" | head -1)" = 'line "q" \ x' ] || fail "unescape: $out"
grep -q -- "-s $tmp/home/claude/.services/emacs/socket --eval (homun-rpc) slate insert text hi" "$tmp/log" || fail "args: $(cat "$tmp/log")"
for pair in unknown:3 invalid:4 timeout:5 failed:1; do
  code=${pair#*:}; kind=${pair%:*}
  set +e; run "\"err $kind\nm\"" a b 2>/dev/null; rc=$?; set -e
  [ "$rc" = "$code" ] || fail "$kind gave $rc"
done
run '"ok\nx"' slate help >/dev/null; grep -q "api list object slate" "$tmp/log" || fail help
run '"ok\nx"' >/dev/null; grep -q "api list$" "$tmp/log" || fail bare
echo ok
