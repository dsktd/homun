;;; init.el --- Claude's Emacs -*- lexical-binding: t -*-

;; Runs as the `emacs' service in the Manager container (see
;; container/services/emacs/run): a daemon whose socket is
;; ~/claude/.services/emacs/socket/server on both sides of the container, with
;; pgtk frames on the host's Wayland display. The packages come from the Nix
;; profile (emacs.nix), so every `require' below is optional: the config also
;; loads in a bare Emacs, which is how the tests check it. Doom-shaped
;; bindings so the user's fingers work; claude.el holds what the
;; `claude-emacs' CLI calls.

(add-to-list 'load-path (file-name-directory load-file-name))

;;; Server

(require 'server)
(setq server-socket-dir (expand-file-name "socket" claude-service-dir)
      server-name "server")

;; A client sends its own display, which from the host is the host's name
;; (e.g. wayland-1) and does not exist in here; a pgtk Emacs exits when it
;; cannot open a display. Put every frame on the mounted socket instead.
(define-advice server-create-window-system-frame
    (:filter-args (args) claude-display)
  (cons (getenv "WAYLAND_DISPLAY") (cdr args)))

;;; Files and state: nothing outside user-emacs-directory

(setq make-backup-files nil
      auto-save-default nil
      create-lockfiles nil
      auto-save-list-file-prefix (expand-file-name "auto-save-list/.saves-" user-emacs-directory)
      custom-file (expand-file-name "custom.el" user-emacs-directory)
      confirm-kill-emacs nil
      inhibit-startup-screen t
      ring-bell-function #'ignore
      use-short-answers t
      frame-title-format "claude-emacs")
(setq-default indent-tabs-mode nil)
(savehist-mode 1)
(recentf-mode 1)
(global-auto-revert-mode 1)

;;; Look

(menu-bar-mode -1)
(when (fboundp 'tool-bar-mode) (tool-bar-mode -1))
(when (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))
(push '(font . "JetBrains Mono-11") default-frame-alist)
(push '(width . 120) default-frame-alist)
(push '(height . 40) default-frame-alist)
(column-number-mode 1)
(add-hook 'prog-mode-hook #'display-line-numbers-mode)
(when (require 'doom-themes nil t)
  (load-theme 'doom-one t))
(when (require 'diff-hl nil t)
  (global-diff-hl-mode 1))

;;; Completion

(when (require 'vertico nil t)
  (vertico-mode 1))
(when (require 'orderless nil t)
  (setq completion-styles '(orderless basic)
        completion-category-overrides '((file (styles basic partial-completion)))))
(when (require 'marginalia nil t)
  (marginalia-mode 1))
(when (require 'which-key nil t)
  (which-key-mode 1))

;;; Evil, with SPC as leader

(setq evil-want-keybinding nil
      evil-want-C-u-scroll t
      evil-undo-system 'undo-redo
      evil-split-window-below t
      evil-vsplit-window-right t)
(when (require 'evil nil t)
  (evil-mode 1)
  (when (require 'evil-collection nil t)
    (evil-collection-init))
  (evil-set-leader '(normal visual) (kbd "SPC"))
  (evil-define-key '(normal visual) 'global
    (kbd "<leader>:") #'execute-extended-command
    (kbd "<leader>.") #'find-file
    (kbd "<leader>,") #'switch-to-buffer
    (kbd "<leader>ff") #'find-file
    (kbd "<leader>fr") #'recentf-open-files
    (kbd "<leader>fs") #'save-buffer
    (kbd "<leader>bb") #'switch-to-buffer
    (kbd "<leader>bd") #'kill-current-buffer
    (kbd "<leader>bn") #'next-buffer
    (kbd "<leader>bp") #'previous-buffer
    (kbd "<leader>gg") #'magit-status
    (kbd "<leader>wv") #'split-window-right
    (kbd "<leader>ws") #'split-window-below
    (kbd "<leader>wd") #'delete-window
    (kbd "<leader>wm") #'delete-other-windows
    (kbd "<leader>wh") #'windmove-left
    (kbd "<leader>wj") #'windmove-down
    (kbd "<leader>wk") #'windmove-up
    (kbd "<leader>wl") #'windmove-right
    (kbd "<leader>qf") #'delete-frame))

(when (require 'treebundel nil t)
  (setq treebundel-workspace-root (expand-file-name "~/claude/"))
  (when (boundp 'evil-mode)
    (evil-define-key '(normal visual) 'global
      (kbd "<leader>pp") #'treebundel-open
      (kbd "<leader>pw") #'treebundel-open-project)))

(require 'claude)

;;; init.el ends here
