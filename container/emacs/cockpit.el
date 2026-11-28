;;; cockpit.el --- What every cockpit configuration loads: the views and the container glue -*- lexical-binding: t -*-

;; The cockpit is one Emacs daemon in a container of its own (container/services/emacs/run):
;; its socket is ~/claude/.services/emacs/socket on both sides of the container and its pgtk
;; frames open on the host's Wayland display.  This file is the part of its configuration
;; that does not depend on how Emacs itself is set up: the plain configuration (init.el) and
;; the Doom flavour (doom/local.el) both end up here.  It is read from the live checkout
;; mount, so an edit applies on a restart of the daemon, without a build.

;;; Code:

(defconst claude-cockpit-directory
  (file-name-directory (or load-file-name buffer-file-name "/opt/homun/emacs/"))
  "Where the cockpit's Elisp lives.")

;;; Frames on the host's display

;; A client sends its own display, which from the host is the host's name
;; (e.g. wayland-1) and does not exist in here; a pgtk Emacs exits when it
;; cannot open a display. Put every frame on the mounted socket instead.
(define-advice server-create-window-system-frame
    (:filter-args (args) claude-display)
  (unless (or (not (fboundp (quote claude-display-reachable-p))) (claude-display-reachable-p))
    (error "No Wayland display at %s" (getenv "WAYLAND_DISPLAY")))
  (cons (getenv "WAYLAND_DISPLAY") (cdr args)))

;; The sources' directory, set before anything else: files find their siblings from it
(add-to-list 'load-path (directory-file-name claude-cockpit-directory))
(require 'homun-dir)
(require 'claude-errwatch)
(require 'homun-freeze-watch)
(unless noninteractive (homun-freeze-watch-mode 1))

(defconst claude-cockpit-profile "/nix/var/nix/profiles/emacs"
  "The Nix profile the cockpit's Emacs, fonts and tools are installed
into (flake.nix).")

(defvar treebundel-workspace-root)
(defvar x-gtk-use-system-tooltips)
(defvar denote-directory)

(add-to-list 'load-path (expand-file-name "widgetry" claude-cockpit-directory))

;; Compiled copies of the sources, ahead of them on `load-path'; a file that did not compile
;; has none there and loads from source.  Without Emacs able to build them, all load from source.
(defvar homun-elc-enabled t)
(require 'homun-elc)
(when homun-elc-enabled (homun-elc-enable))

(require 'claude-gc)
(require 'claude-settings)
(claude-settings-load)
(require 'claude)
(require 'claude-focus)
(require 'claude-dashboard)
(require 'claude-tracker)
(require 'claude-homun)
(require 'claude-events)
(require 'claude-attn)
(claude-attn-start)
(require 'claude-glance)
(claude-glance-start)
(require 'claude-links)
(claude-events-start)
(require 'claude-questions)
(require 'claude-reload)
(require 'homun-scroll)
(claude-reload-start)
(autoload 'claude-transcript "claude-transcript" "Open a session's transcript." t)
(autoload 'claude-follow "claude-follow" "Show what Claude sessions edit." t)
(autoload 'claude-follow-toggle-auto "claude-follow" "Turn follow's auto-follow on or off." t)

;; Clipboard: pgtk's own Wayland data transfer does not reach the host's clipboard through the
;; forwarded socket, but wl-copy and wl-paste do (checked 2026-11-23): use them for the system
;; selection, from the cockpit's own profile, never PATH.
(defun claude-wl--bin (name)
  (expand-file-name (concat "bin/" name) claude-cockpit-profile))

(defun claude-wl-copy (text)
  "Make TEXT the clipboard through wl-copy on the forwarded socket."
  (when (and (stringp text) (file-executable-p (claude-wl--bin "wl-copy")))
    (let ((process-environment (cons (concat "WAYLAND_DISPLAY=" (getenv "WAYLAND_DISPLAY"))
                                     process-environment))
          (process (make-process :name "wl-copy" :buffer nil :noquery t
                                 :connection-type 'pipe
                                 :command (list (claude-wl--bin "wl-copy") "--type" "text/plain"))))
      (process-send-string process text)
      (process-send-eof process))))

(defun claude-wl-paste ()
  "The clipboard text through wl-paste, or nil when it is empty or not text."
  (when (file-executable-p (claude-wl--bin "wl-paste"))
    (with-temp-buffer
      (when (zerop (call-process (claude-wl--bin "wl-paste") nil '(t nil) nil
                                 "--no-newline" "--type" "text"))
        (and (> (buffer-size) 0) (buffer-string))))))

(when (file-executable-p (claude-wl--bin "wl-copy"))
  (setq interprogram-cut-function #'claude-wl-copy
        interprogram-paste-function #'claude-wl-paste))

(setq frame-title-format "claude-emacs")
(push '(width . 120) default-frame-alist)
(push '(height . 40) default-frame-alist)

;; pulse.el decides `pulse-flag' when it loads, and the daemon has no display
;; then, which would leave every pulse (claude-follow's included) off
(setq pulse-flag t)

;; Hover help is drawn by Emacs as a themed tooltip, never in the echo area (Doom turns
;; tooltip-mode off, which sends help-echo there; a terminal frame gets none at all)
(require 'color)
(declare-function recentf-save-list "recentf")
(declare-function savehist-autosave "savehist")

(defun claude-tooltips-show-help (help)
  "`show-help-function': a tooltip on a graphical frame, nothing in the echo area
elsewhere."
  (when (display-graphic-p) (tooltip-show-help help)))

(defun claude-tooltips-apply (&rest _)
  "Turn tooltips on and style them from the theme (run again after a theme change)."
  (setq x-gtk-use-system-tooltips nil
        tooltip-delay 0.6
        tooltip-short-delay 0.1)
  (when (boundp 'use-system-tooltips) (setq use-system-tooltips nil))
  (tooltip-mode 1)
  (setq show-help-function #'claude-tooltips-show-help)
  (when (and (display-graphic-p) (color-name-to-rgb (face-background 'default nil t)))
    (let* ((bg (face-background 'default nil t))
          (fg (face-foreground 'default nil t))
          (dark (< (apply #'+ (or (color-name-to-rgb bg) '(0 0 0))) 1.5))
          (box (color-name-to-rgb fg))
          (back (color-name-to-rgb bg))
          (border (apply #'color-rgb-to-hex
                         (append (cl-mapcar (lambda (f b) (+ (* 0.35 f) (* 0.65 b))) box back) '(2)))))
      (set-face-attribute 'tooltip nil :inherit 'default :family (face-attribute 'default :family nil t)
                          :height 0.9 :foreground fg
                          :background (if dark (color-lighten-name bg 7) (color-darken-name bg 5)))
      (setq tooltip-frame-parameters
            `((name . "tooltip") (internal-border-width . 6) (border-width . 1)
              (border-color . ,border) (no-special-glyphs . t))))))

(claude-tooltips-apply)
(add-hook 'enable-theme-functions #'claude-tooltips-apply)
;; The daemon has no display when this loads: style them when a frame opens
(add-hook 'server-after-make-frame-hook #'claude-tooltips-apply)

;; A divider wide enough to drag between side-by-side windows
(setq window-divider-default-places 'right-only
      window-divider-default-right-width 6)
(window-divider-mode 1)

;; A terminal frame (`homun editor tty', from the phone) takes taps and drags
;; as mouse events. `tty-setup-hook' runs once per new tty terminal, never for
;; a pgtk frame, and the mode then reads mouse input on every tty terminal
(defun claude-tty-mouse-h ()
  "Read mouse events in the new terminal frame."
  (xterm-mouse-mode 1))
(add-hook 'tty-setup-hook #'claude-tty-mouse-h)

;;; The container's paths

(defvar browse-url-secondary-browser-function)
;; browse-url from any code asks the host (claude.el); eww still follows its own links
(setq browse-url-browser-function #'claude-browse-url
      browse-url-secondary-browser-function #'claude-browse-url)

;; treebundel, when the configuration has it, over ~/claude, the workspace root
;; (feature/ and .bare are its defaults already)
(setq treebundel-workspace-root (expand-file-name "~/claude/"))

;; Notes stay with the service, not in the user's ~/.org
(setq org-directory (expand-file-name "~/claude/.services/emacs/org/"))
(with-eval-after-load 'denote
  (setq denote-directory (expand-file-name "~/claude/.services/emacs/notes/")))

;; Grammars installed by flake.nix (libtree-sitter-<lang>.so in the profile)
(add-to-list 'treesit-extra-load-path (expand-file-name "lib" claude-cockpit-profile))

(defun claude-status ()
  "Open the status page in the host browser (this container's 127.0.0.1 is not the
Manager's)."
  (interactive)
  (claude-browse-url "http://127.0.0.1:8080/status/"))

;;; History: the container ends without a clean kill-emacs, so the hooks that
;;; save recentf and savehist never run; save both when idle instead

(run-with-idle-timer
 30 t (lambda ()
        (let ((inhibit-message t))
          (when (bound-and-true-p recentf-mode) (recentf-save-list))
          (when (bound-and-true-p savehist-mode) (savehist-autosave)))))

(provide 'cockpit)
;;; cockpit.el ends here
