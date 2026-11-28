#!/bin/sh
# The whole ERT suite (tests/el plus the widgetry tests), headless, with the cockpit's plain
# Emacs from the flake (magit-section and friends); no Doom, no daemon. Extra args go to Emacs
# (for example: --eval '(setq ert-quiet t)' or -f ert-run-tests-batch-and-exit "selector" via SEL).
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
emacs=$(nix build "$root/container/emacs#default" --no-link --print-out-paths)/bin/emacs
loads=""
for f in "$root"/tests/el/*-test.el "$root"/container/emacs/widgetry/test/*-test.el; do
    loads="$loads -l $f"
done
# No test reaches a live spool: ~/claude/.services is a scratch dir under a temp HOME
HOME=$(mktemp -d /var/tmp/homun-test-home-XXXXXX)
export HOME
trap 'rm -rf "$HOME"' EXIT
# shellcheck disable=SC2086
"$emacs" -Q --batch -L "$root/container/emacs" -L "$root/container/emacs/widgetry" \
    -L "$root/container/emacs/widgetry/test" $loads \
    --eval "(ert-run-tests-batch-and-exit ${SEL:-t})"
