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
      ;; Doom's scrolling: keep 10 lines of context (the user's scroll-margin),
      ;; move line by line instead of recentering
      scroll-margin 10
      scroll-conservatively 101
      scroll-preserve-screen-position t
      display-line-numbers-type 'relative
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
(pixel-scroll-precision-mode 1)
(dolist (hook '(prog-mode-hook text-mode-hook conf-mode-hook))
  (add-hook hook #'display-line-numbers-mode))
;; The user's Doom theme; built into Emacs, so no package
(load-theme 'modus-vivendi t)
(when (require 'doom-modeline nil t)
  (setq doom-modeline-buffer-file-name-style 'relative-to-project)
  (doom-modeline-mode 1))
(when (require 'hl-todo nil t)
  (global-hl-todo-mode 1))
(when (require 'vi-tilde-fringe nil t)
  (global-vi-tilde-fringe-mode 1))
(when (require 'diff-hl nil t)
  (global-diff-hl-mode 1)
  (add-hook 'magit-post-refresh-hook #'diff-hl-magit-post-refresh))

;;; Completion

(when (require 'vertico nil t)
  (vertico-mode 1))
(when (require 'orderless nil t)
  (setq completion-styles '(orderless basic)
        completion-category-overrides '((file (styles basic partial-completion)))))
(when (require 'marginalia nil t)
  (marginalia-mode 1))
(when (require 'consult nil t)
  (setq xref-show-xrefs-function #'consult-xref
        xref-show-definitions-function #'consult-xref))
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
    ;; evil-collection binds SPC in many mode maps (dired: dired-next-line), which
    ;; would shadow the leader there; keep SPC out of all of them
    (setq evil-collection-key-blacklist '("SPC"))
    (evil-collection-init))
  (evil-set-leader '(normal visual motion) (kbd "SPC"))
  ;; consult's versions when it is there, the built-ins otherwise
  (let ((buffer (if (fboundp 'consult-buffer) #'consult-buffer #'switch-to-buffer))
        (recent (if (fboundp 'consult-recent-file) #'consult-recent-file #'recentf-open-files)))
    (evil-define-key '(normal visual motion) 'global
      (kbd "<leader>,") buffer
      (kbd "<leader>bb") buffer
      (kbd "<leader>fr") recent))
  (when (fboundp 'consult-line)
    (evil-define-key '(normal visual motion) 'global
      (kbd "<leader>ss") #'consult-line
      (kbd "<leader>si") #'consult-imenu
      (kbd "<leader>sr") #'consult-ripgrep
      (kbd "<leader>sp") #'consult-ripgrep
      (kbd "<leader>bB") #'consult-buffer))
  (evil-define-key '(normal visual motion) 'global
    (kbd "G") #'end-of-buffer           ; the user's own remap
    (kbd "<leader>:") #'execute-extended-command
    (kbd "<leader>.") #'find-file
    (kbd "<leader>`") #'evil-switch-to-windows-last-buffer
    (kbd "<leader>y") #'claude-yank-whole-buffer
    (kbd "<leader>ff") #'find-file
    (kbd "<leader>fs") #'save-buffer
    (kbd "<leader>fy") #'claude-yank-file-name
    (kbd "<leader>bk") #'kill-current-buffer
    (kbd "<leader>br") #'revert-buffer
    (kbd "<leader>bd") #'kill-current-buffer
    (kbd "<leader>bn") #'next-buffer
    (kbd "<leader>bp") #'previous-buffer
    (kbd "<leader>gg") #'magit-status
    (kbd "<leader>gb") #'magit-blame-addition
    (kbd "<leader>gl") #'magit-log-buffer-file
    (kbd "<leader>gr") #'diff-hl-revert-hunk
    (kbd "<leader>g]") #'diff-hl-next-hunk
    (kbd "<leader>g[") #'diff-hl-previous-hunk
    (kbd "]d") #'diff-hl-next-hunk
    (kbd "[d") #'diff-hl-previous-hunk
    (kbd "<leader>ww") #'other-window
    (kbd "<leader>wc") #'delete-window
    (kbd "<leader>w=") #'balance-windows
    (kbd "<leader>wv") #'split-window-right
    (kbd "<leader>ws") #'split-window-below
    (kbd "<leader>wd") #'delete-window
    (kbd "<leader>wm") #'delete-other-windows
    (kbd "<leader>wh") #'windmove-left
    (kbd "<leader>wj") #'windmove-down
    (kbd "<leader>wk") #'windmove-up
    (kbd "<leader>wl") #'windmove-right
    (kbd "<leader>qf") #'delete-frame
    (kbd "<leader>qq") #'delete-frame
    (kbd "<leader>cq") #'claude-queue
    (kbd "<leader>cs") #'claude-status
    (kbd "<leader>cd") #'claude-dashboard
    (kbd "<leader>ca") #'org-agenda
    (kbd "<leader>hf") #'describe-function
    (kbd "<leader>hv") #'describe-variable
    (kbd "<leader>hk") #'describe-key
    (kbd "<leader>hm") #'describe-mode
    (kbd "<leader>h.") #'describe-symbol)
  ;; diff-mode (claude-emacs diff): Doom's ]h/[h between hunks, ]f/[f between files
  (with-eval-after-load 'diff-mode
    (evil-define-key '(normal motion) diff-mode-map
      (kbd "]h") #'diff-hunk-next (kbd "[h") #'diff-hunk-prev
      (kbd "]f") #'diff-file-next (kbd "[f") #'diff-file-prev)))

(defun claude-status ()
  "Open the status page in eww (the container has no other browser)."
  (interactive)
  (eww "http://127.0.0.1:8421/"))

(defun claude-yank-whole-buffer ()
  "Copy the whole buffer (the user's SPC y)."
  (interactive)
  (kill-new (buffer-substring-no-properties (point-min) (point-max)))
  (message "Yanked whole buffer"))

(defun claude-yank-file-name ()
  "Copy the visited file's path (Doom's SPC f y)."
  (interactive)
  (when-let* ((name (or buffer-file-name default-directory)))
    (kill-new name)
    (message "%s" name)))

;;; Markdown and diffs, the things Claude shows

(when (fboundp 'gfm-mode)
  (add-to-list 'auto-mode-alist '("\\.md\\'" . gfm-mode))
  (setq markdown-fontify-code-blocks-natively t
        markdown-header-scaling t))
(setq diff-font-lock-prettify t
      diff-refine 'font-lock)

;; The user's treebundel (their fork, built in emacs.nix) over ~/claude, the
;; Manager's workspace root; feature/ and .bare are its defaults already.
;; Like their config: SPC p is its transient, a new project opens in magit.
(setq treebundel-workspace-root (expand-file-name "~/claude/"))
(when (require 'treebundel nil t)
  (defvar magit-display-buffer-function)
  (defun claude-treebundel-open-project (project-path)
    "Open PROJECT-PATH's magit status full-frame (the user's pg/open-new-project)."
    (when-let* ((workspace (treebundel-current-workspace project-path))
                (project (treebundel--project-of project-path)))
      (require 'magit nil t)
      (let ((magit-display-buffer-function #'magit-display-buffer-fullframe-status-v1))
        (magit-status-setup-buffer (treebundel-project-path workspace project)))))
  (setq treebundel-project-open-function #'claude-treebundel-open-project)
  (when (featurep 'evil)
    (evil-define-key '(normal visual motion) 'global
      (kbd "<leader>p") #'treebundel)))

(require 'claude)
(require 'claude-focus)

;; A client frame starts on the Manager's focus, else the dashboard
(when (require 'claude-dashboard nil t)
  (setq initial-buffer-choice #'claude-dashboard-initial-buffer))

;;; init.el ends here
