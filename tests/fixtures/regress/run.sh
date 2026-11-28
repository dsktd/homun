#!/bin/sh
# Regression fixtures: one file per past fix of the bus/claims, the roll order and the pin, each
# naming its fix commit on a "# fixes: <sha>" line. A fixture takes a source tree and exits 0 when
# the fix holds there.
#   sh tests/fixtures/regress/run.sh            every fixture against this tree
#   sh tests/fixtures/regress/run.sh parents    also each against its fix's parent (must fail there)
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
fails=0
fixture() { # fixture <file> <root>
	case $1 in *.nu) nu -I "$2/lib" "$1" "$2" ;; *) sh "$1" "$2" ;; esac >/dev/null 2>"$tmp/err"
}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for f in "$here"/*.sh "$here"/*.nu; do
	n=${f##*/}
	[ "$n" = run.sh ] && continue
	if fixture "$f" "$repo"; then echo "ok   $n"; else fails=$((fails + 1)); echo "FAIL $n: $(tail -n 3 "$tmp/err")"; fi
	[ "${1:-}" = parents ] || continue
	sha=$(sed -n 's/^# fixes: \([0-9a-f]*\).*/\1/p' "$f" | head -n 1)
	old=$tmp/parent; rm -rf "$old"; mkdir "$old"
	git -C "$repo" archive "$sha^" | tar -xf - -C "$old"
	if fixture "$f" "$old"; then fails=$((fails + 1)); echo "FAIL $n: passes on $sha^ too"; else echo "ok   $n fails on $sha^"; fi
done
[ "$fails" -eq 0 ]
