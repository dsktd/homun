;;; claude-pick.el --- One quick choice in the minibuffer -*- lexical-binding: t -*-

;; `claude-pick' asks the user to choose one of a few strings.  It returns at once;
;; a timer shows the choices in the minibuffer (all listed immediately) and the
;; answer lands in answers/ID as JSON {"status": "ok|cancel|timeout", "choice": ...}.
;; For anything with notes or several questions use claude-questions instead.

(require 'json)
(require 'subr-x)
(require 'claude)

(defun claude-pick--table (choices)
  "A completion table over CHOICES that lists them all at once, in order."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        '(metadata (category . claude-pick) (eager-display . t)
                   (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action choices string predicate))))

(defun claude-pick--write (id status &optional choice)
  "Write the result of pick ID, atomically, for the CLI to read."
  (make-directory claude-answers-dir t)
  (let* ((file (expand-file-name id claude-answers-dir))
         (tmp (concat file ".tmp")))
    (write-region (json-serialize (list :status status :choice (or choice :null)))
                  nil tmp nil 'silent)
    (rename-file tmp file t)))

(defun claude-pick--ask (id prompt choices timeout)
  "Read one of CHOICES for TIMEOUT seconds at most; write the result for ID."
  (let ((result (list 'cancel)))
    (condition-case nil
        (with-selected-frame (claude--gui-frame)
          (select-frame-set-input-focus (selected-frame))
          (let ((completion-eager-display t)
                (minibuffer-message-timeout 0))
            (setq result
                  (with-timeout (timeout (list 'timeout))
                    (list 'ok (completing-read (concat prompt ": ")
                                               (claude-pick--table choices)
                                               nil t))))))
      (quit nil)
      (error nil))
    (apply #'claude-pick--write id result)))

(defun claude-pick (id prompt choices timeout)
  "Ask PROMPT with CHOICES (a list of strings) on a timer; answer to answers/ID.
Gives up after TIMEOUT seconds.  Returns ID without waiting."
  (run-at-time 0 nil #'claude-pick--ask id prompt choices timeout)
  (claude--notify "Claude asks" prompt)
  id)

(provide 'claude-pick)
;;; claude-pick.el ends here
