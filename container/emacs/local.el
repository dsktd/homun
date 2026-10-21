;;; local.el --- Claude's Emacs: the container's glue over Cal's Doom config -*- lexical-binding: t -*-

;; The last file Cal's config.el loads ((load! "local" nil t), the gitignored
;; machine-local slot), laid over their doom/ by flake.nix. It runs as the
;; `emacs' service in the Manager container (container/services/emacs/run): a
;; daemon whose socket is ~/claude/.services/emacs/socket/server on both sides
;; of the container, with pgtk frames on the host's Wayland display. Everything
;; that is Doom's or Cal's (look, evil, completion, magit, treebundel's own
;; setup) is theirs; this is only what the container adds.

;;; The claude*.el files, from the live checkout mount (edits apply on a restart)

(add-to-list 'load-path (or (getenv "CLAUDE_EMACS_CONF") "/opt/claude-wrapper/emacs"))
(require 'claude)
(require 'claude-focus)
(require 'claude-dashboard)
(autoload 'claude-follow "claude-follow" "Show what Claude sessions edit." t)
(autoload 'claude-follow-toggle-auto "claude-follow" "Turn follow's auto-follow on or off." t)

;;; Frames on the host's display

;; A client sends its own display, which from the host is the host's name
;; (e.g. wayland-1) and does not exist in here; a pgtk Emacs exits when it
;; cannot open a display. Put every frame on the mounted socket instead.
(define-advice server-create-window-system-frame
    (:filter-args (args) claude-display)
  (cons (getenv "WAYLAND_DISPLAY") (cdr args)))

(setq doom-font (font-spec :family "JetBrains Mono" :size 11.0)
      frame-title-format "claude-emacs")
(push '(width . 120) default-frame-alist)
(push '(height . 40) default-frame-alist)

;; A client frame starts on the Manager's focus, else the dashboard. Doom's
;; dashboard module points `initial-buffer-choice' at its own splash buffer
;; from `doom-init-ui-hook', which runs after this file: take it back there.
(defun claude-initial-buffer-h ()
  "Make a new client frame start on the Manager's focus or the dashboard."
  (setq initial-buffer-choice #'claude-dashboard-initial-buffer))
(add-hook 'doom-init-ui-hook #'claude-initial-buffer-h 'append)

;; pulse.el decides `pulse-flag' when it loads, and the daemon has no display
;; then, which would leave every pulse (claude-follow's included) off
(setq pulse-flag t)

;;; The container's paths

;; browse-url from any code asks the host (claude.el); eww still follows its own links
(setq browse-url-browser-function #'claude-browse-url
      browse-url-secondary-browser-function #'claude-browse-url)

;; treebundel over ~/claude, the Manager's workspace root (feature/ and .bare
;; are its defaults already; Cal's config.el does the rest)
(setq treebundel-workspace-root (expand-file-name "~/claude/"))

;; Notes stay with the service, not in Cal's ~/.org
(setq org-directory (expand-file-name "~/claude/.services/emacs/org/"))
(after! denote
  (setq denote-directory (expand-file-name "~/claude/.services/emacs/notes/")))

(defun claude-status ()
  "Open the status page in eww (the container has no other browser)."
  (interactive)
  (eww "http://127.0.0.1:8421/"))

;;; Keys: the claude commands under Doom's open prefix, SPC o c

(map! :leader
      (:prefix ("o c" . "claude")
       :desc "Dashboard"          "d" #'claude-dashboard
       :desc "Follow edits"       "f" #'claude-follow
       :desc "Toggle auto-follow" "F" #'claude-follow-toggle-auto
       :desc "Queue"              "q" #'claude-queue
       :desc "Status page"        "s" #'claude-status
       :desc "Agenda"             "a" #'org-agenda))

;;; local.el ends here
