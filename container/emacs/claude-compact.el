;;; claude-compact.el --- Send /compact to the Manager's TUI -*- coding: utf-8; lexical-binding: t -*-

;; `claude-compact' (M-x, the ⋮ button on the board) asks the Manager's compact-relay
;; (container/compact-relay, around the Manager's claude in start.sh) to type /compact
;; when the TUI is idle.  Emacs writes "<epoch> compact" to
;; compact/emacs-request/request; that directory is rw in this container alone (run.nu
;; `compact-inbox').  The relay only ever types a word of its fixed allowlist.  Nothing
;; else may write it: no homun-api entry.  The answer is compact/emacs-result.

(require 'claude)

(defconst claude-compact-dir (expand-file-name "claude/.services/compact" "~"))

(defun claude-compact--result (stamp)
  "The relay's answer to request STAMP, or nil."
  (let ((file (expand-file-name "emacs-result" claude-compact-dir)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (let ((text (string-trim (buffer-string))))
          (when (string-prefix-p (format "%d " stamp) text)
            (substring text (1+ (length (format "%d" stamp))))))))))

(defun claude-compact--report (stamp)
  (let ((result (claude-compact--result stamp)))
    (cond ((null result) (message "Compact requested; the relay has not answered (needs a rebuild?)"))
          ((equal result "ok") (message "Compact typed into %s; progress shows in the mode line" claude-agent-name))
          (t (message "Compact %s" result)))))

;;;###autoload
(defun claude-compact (&optional confirmed)
  "Compact the manager's conversation (/compact when the manager is idle), after
asking
(`claude-confirm').
CONFIRMED skips the question: the board's Compact button is the confirmation."
  (interactive)
  (when (or confirmed (claude-confirm (format "Compact %s's conversation now? " claude-agent-name)))
    (let ((stamp (floor (float-time))))
      (write-region (format "%d compact\n" stamp) nil
                    (expand-file-name "emacs-request/request" claude-compact-dir))
      (message "Compact requested...")
      (run-at-time 25 nil #'claude-compact--report stamp))))

(provide 'claude-compact)
;;; claude-compact.el ends here
