;;; local.el --- The cockpit over a Doom configuration: the Doom flavour's glue -*- lexical-binding: t -*-

;; The last file a Doom config.el loads ((load! "local" nil t), the machine-local slot),
;; laid over the host's Doom directory (host config key cockpit.config) by flake.nix.
;; Everything that is Doom's or the user's (look, evil, completion, magit) is theirs; the
;; cockpit itself comes from cockpit.el in the live checkout mount, so only a change to
;; this file needs a new build.

(load (expand-file-name "cockpit" (or (getenv "CLAUDE_EMACS_CONF") "/opt/homun/emacs")) nil t)

(setq doom-font (font-spec :family "JetBrains Mono" :size 11.0))
;; A new frame is white until Doom applies the theme from
;; `server-after-make-frame-hook', which shows as a flash: start it on the
;; theme's own colours (modus-vivendi's black and white)
(push '(background-color . "#000000") default-frame-alist)
(push '(foreground-color . "#ffffff") default-frame-alist)

;; A client frame starts on the Manager's focus, else the dashboard. Doom's
;; dashboard module points `initial-buffer-choice' at its own splash buffer
;; from `doom-init-ui-hook', which runs after this file: take it back there.
(defun claude-initial-buffer-h ()
  "Make a new client frame start on the Manager's focus or the dashboard."
  (setq initial-buffer-choice #'claude-dashboard-initial-buffer))
(add-hook 'doom-init-ui-hook #'claude-initial-buffer-h 'append)

;;; Keys: SPC o c opens `claude-homun', the menu of every claude command (its
;;; keys are the old SPC o c ones, so SPC o c d and the rest still work)

;; `map!' :leader is a plain `define-key' on `doom-leader-map' when its form is evaluated, with no
;; priority: whichever form runs last wins, and a user's own "o c" inside `after!', a hook or a
;; package's :config runs after this file. So bind it now and again once Doom has finished
;; starting (`doom-after-init-hook', after those), where it is the last word.
(defun claude-bind-homun-key-h ()
  "Bind SPC o c to `claude-homun' on `doom-leader-map', over any binding of the user's."
  (define-key doom-leader-map (kbd "o c") (cons "Manager" #'claude-homun)))
(claude-bind-homun-key-h)
(add-hook 'doom-after-init-hook #'claude-bind-homun-key-h 99)

;; No current-line highlight anywhere: Doom's :ui hl-line module turns on
;; global-hl-line-mode from doom-first-buffer-hook, so drop that and force it off
(remove-hook 'doom-first-buffer-hook #'global-hl-line-mode)
(add-hook 'doom-first-buffer-hook (lambda () (global-hl-line-mode -1)) 90)
(global-hl-line-mode -1)

;; Magit's current-section highlight shifts the background as point moves;
;; keep sections flat (diff hunks keep their own highlight faces)
(custom-set-faces! '(magit-section-highlight :background unspecified :inherit unspecified))

;; Doom turns tooltip-mode off while it starts; the cockpit wants Emacs-drawn tooltips
(add-hook 'doom-after-init-hook #'claude-tooltips-apply 95)

;;; local.el ends here
