;;; init.el --- The cockpit's plain configuration: stock Emacs, no framework -*- lexical-binding: t -*-

;; What a host gets when its config names no flavour: the Emacs and packages of flake.nix's
;; default package, started by container/services/emacs/run with this file.  It sets up
;; Emacs just enough to be pleasant, then loads the cockpit (cockpit.el), then the
;; host's own init.el when cockpit.config names a directory that has one.

;;; Code:

(setq inhibit-startup-screen t
      ring-bell-function #'ignore
      use-short-answers t
      make-backup-files nil
      create-lockfiles nil
      custom-file (locate-user-emacs-file "custom.el"))
(menu-bar-mode -1)
(when (fboundp 'tool-bar-mode) (tool-bar-mode -1))
(when (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))
(load-theme 'modus-vivendi t)
(push '(font . "JetBrains Mono-11") default-frame-alist)
;; A new frame starts on the theme's colours instead of flashing white
(push '(background-color . "#000000") default-frame-alist)
(push '(foreground-color . "#ffffff") default-frame-alist)

(fido-vertical-mode 1)
(which-key-mode 1)
(savehist-mode 1)
(recentf-mode 1)
(global-auto-revert-mode 1)

(load (expand-file-name "cockpit" (file-name-directory load-file-name)) nil t)

;; A client frame starts on the Manager's focus, else the dashboard
(setq initial-buffer-choice #'claude-dashboard-initial-buffer)

;; C-c c opens `claude-homun', the menu of every cockpit command
(keymap-global-set "C-c c" #'claude-homun)

;; The host's own configuration, over all of the above
(when-let* ((dir (getenv "HOMUN_COCKPIT_CONFIG"))
            (file (expand-file-name "init.el" dir))
            ((file-readable-p file)))
  (load file nil t))

;;; init.el ends here
