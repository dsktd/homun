;;; early-init.el --- Claude's Emacs: keep state out of the init directory -*- lexical-binding: t -*-

;; The init directory (--init-directory) is /opt/claude-wrapper/emacs, the
;; read-only mount of the wrapper checkout. Everything Emacs writes (packages
;; it might fetch, native-compiled files, history) goes under the service's
;; state directory instead, which lives on ~/claude and survives a recreate.

(defconst claude-service-dir (expand-file-name "~/claude/.services/emacs/")
  "The emacs service's directory: socket/, state/ and answers/ live here.")

(setq user-emacs-directory (expand-file-name "state/" claude-service-dir))
(make-directory user-emacs-directory t)
(when (fboundp 'startup-redirect-eln-cache)
  (startup-redirect-eln-cache (expand-file-name "eln-cache/" user-emacs-directory)))

;;; early-init.el ends here
