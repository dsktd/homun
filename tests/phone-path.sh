#!/bin/sh
# The phone's real pairing path, end to end (run on demand, not part of tests/run.nu):
# the proxy's TLS certificate for the LAN name, then a vanilla Emacs pairing with a line made
# from the deployed homun-init.el.  Dials 127.0.0.1 (the container cannot reach the LAN) but
# verifies the LAN name, as the phone does with an IP and no SNI.
#   tests/phone-path.sh [line-file | repair]
# The device emulator-pathtest stays paired: its Emacs home is kept in .services/phone-path/, and
# later runs start from its init.el (fresh fetch of the CA and every file, no new approval).
# `repair` (or a line-file) pairs again, which needs Cal's approval once.
# line-file: the pairing line of a device named emulator-pathtest.  Without it the script asks
# the daemon (`homun-emacs remote pair name emulator-pathtest`); the MCP remote_pair tool needs
# Cal's approval, so when that fails make the line there and pass its file.
set -eu
proxy=$HOME/claude/.services/proxy
gw=$HOME/claude/.services/cockpit-gateway
st=$HOME/claude/.services/phone-path
name=$(grep -m1 -E '^[A-Za-z0-9._-]+$' "$proxy/hosts")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

nix shell nixpkgs#gnutls -c gnutls-cli --x509cafile "$proxy/root.crt" --verify-hostname "$name" \
  --port 8443 127.0.0.1 </dev/null >"$tmp/tls" 2>&1 || { cat "$tmp/tls"; fail "certificate for $name not trusted"; }
echo "ok: certificate trusted for $name"

init=$st/home/.emacs.d/init.el
if [ $# -eq 0 ] && grep -q '^(setq homun-conf .*:key ' "$init" 2>/dev/null; then
  # Paired before: drop the fetched files and the CA, keep init.el with its key
  rm -rf "$st/home/.emacs.d/homun"
  load=$init mode=start
else
  if [ $# -gt 0 ] && [ "$1" != repair ]; then cp "$1" "$tmp/line"
  else "$(dirname "$0")/../bin/homun-emacs" remote pair name emulator-pathtest >"$tmp/pair" 2>&1 || { cat "$tmp/pair"; fail "no pairing line"; }
    # The command prints a cut-down line; the gateway keeps the whole one
    f=$(grep -l emulator-pathtest $(ls -t "$gw"/pair/*.line) 2>/dev/null | head -1)
    [ -n "$f" ] || { cat "$tmp/pair"; fail "no pairing line (approve it, then run again)"; }
    cp "$f" "$tmp/line"; fi
  [ -s "$tmp/line" ] || fail "empty pairing line"
  rm -rf "$st/home" && mkdir -p "$st/home/.emacs.d" && : >"$init"
  load=$tmp/line mode=pair
fi

LOAD=$load NAME=$name HOME=$st/home nix shell nixpkgs#emacs-nox -c emacs -Q --batch --eval '
(let ((lan (getenv "NAME")))
  (advice-add (quote make-network-process) :filter-args
              (lambda (args) (if (equal (plist-get args :host) lan) (plist-put (copy-sequence args) :host "127.0.0.1") args)))
  (setq user-init-file (locate-user-emacs-file "init.el"))
  (load (getenv "LOAD") nil t t)
  (let ((n (length (directory-files (locate-user-emacs-file "homun/") nil "\\.el$"))))
    (unless (> n 0) (error "no files fetched"))
    (unless (featurep (quote claude-remote)) (error "claude-remote not loaded"))
    (with-temp-buffer
      (insert-file-contents user-init-file)
      (unless (re-search-forward "^(setq homun-conf .*:key " nil t) (error "no :key in init.el")))
    (message "ok: %d files fetched, claude-remote loaded, key saved" n)))' >"$tmp/out" 2>&1 || { tail -5 "$tmp/out"; fail "$mode path"; }
echo "$mode: $(tail -1 "$tmp/out")"

# A message through the real compose and send functions must land in the shared bus.
# HOMUN_ELISP=<dir>: load claude-remote*.el from there after the fetched ones (to test a worktree)
# The headless Manager takes the bus file at once, so look for the text in its stream
stream=$HOME/claude/.services/manager/stream/stream.jsonl
stamp="[test] phone-path compose $(date +%s%N)"
STAMP=$stamp LOAD=$init NAME=$name HOME=$st/home nix shell nixpkgs#emacs-nox -c emacs -Q --batch --eval '
(let ((lan (getenv "NAME")) (dir (getenv "HOMUN_ELISP")))
  (advice-add (quote make-network-process) :filter-args
              (lambda (args) (if (equal (plist-get args :host) lan) (plist-put (copy-sequence args) :host "127.0.0.1") args)))
  (setq user-init-file (locate-user-emacs-file "init.el"))
  (load (getenv "LOAD") nil t t)
  (when (and dir (not (string-empty-p dir)))
    (dolist (f (quote ("claude-remote" "claude-remote-home"))) (load (expand-file-name f dir) nil t)))
  (require (quote cl-lib)) (require (quote claude-remote-home))
  ;; The real compose and send; only the window, the transcript view and the keyboard are stubbed (batch has no frames)
  (cl-letf (((symbol-function (quote homun-layout-place)) (lambda (_) (selected-window)))
            ((symbol-function (quote claude-remote-home-transcript)) (function ignore)))
    (claude-remote-home-compose)
    (with-current-buffer claude-remote-home-compose-buffer
      (goto-char (point-max))
      (insert (getenv "STAMP")))
    (claude-remote-home-send))
  (let ((n 0)) (while (and (claude-remote--outbox) (< (cl-incf n) 100)) (accept-process-output nil 0.1)))
  (when (claude-remote--outbox) (error "message still queued: gateway never answered"))
  (message "ok: compose sent"))' >"$tmp/out" 2>&1 || { tail -5 "$tmp/out"; fail "compose send"; }
n=0; until grep -qF "$stamp" "$stream"; do
  n=$((n + 1)); [ $n -lt 30 ] || fail "the send never reached the Manager's stream"; sleep 1; done
echo "ok: compose reached the Manager"
