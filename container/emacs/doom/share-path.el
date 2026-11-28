;;; share-path.el --- container stand-in for the user's private share-path -*- lexical-binding: t -*-
;; Version: 0.1

;; The user's config.el turns on `share-path-mode' from a machine-local package that
;; is not published, so the container has none: without this the void
;; function aborts config.el before its (load! "local" nil t), and local.el
;; never runs. A no-op mode with the variable their config adds to.

(defvar share-path-ignore-dirs nil
  "Directories share-path ignores (unused in the container).")

;;;###autoload
(define-minor-mode share-path-mode
  "No-op stand-in for the user's share-path in the container."
  :global t)

(provide 'share-path)
;;; share-path.el ends here
