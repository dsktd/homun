;;; homun-dir.el --- Where the cockpit's Elisp sources are -*- lexical-binding: t -*-

;; Compiled files live in a cache directory (homun-elc.el), so a file cannot find its
;; siblings (widgetry/, ../homun-doctor, ...) from its own load directory.  This variable is
;; the one answer: cockpit.el loads this file from the source directory first, at startup.

;;; Code:

(defvar homun-cockpit-dir
  (file-name-directory (or load-file-name buffer-file-name "/opt/homun/emacs/"))
  "The directory of the cockpit's Elisp sources (never the compiled cache).")

;; The first form any client sends is (homun-rpc), which homun-api.el defines much later in the
;; start-up: until it does, this stub answers in the API's own wire format ("err KIND" and a
;; message), so the CLI says the cockpit is still starting instead of a void-function error.
(defun homun-rpc ()
  "Stand-in until homun-api.el replaces it: say the cockpit is still starting."
  "err starting\ncockpit still starting, try again in a few seconds")

(provide 'homun-dir)
;;; homun-dir.el ends here
