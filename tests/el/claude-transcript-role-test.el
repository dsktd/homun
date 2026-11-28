;;; claude-transcript-role-test.el --- one transcript buffer per role -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-transcript-role-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'filenotify)
(require 'claude-transcript)

(defun claude-transcript-role-test--file (dir name)
  (let ((f (expand-file-name name dir)))
    (with-temp-file f
      (insert "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hi " name "\"}}\n"))
    f))

(ert-deftest claude-transcript-role-session-change-keeps-one-buffer ()
  (let* ((dir (make-temp-file "role" t))
         (old (claude-transcript-role-test--file dir "a.jsonl"))
         (new (claude-transcript-role-test--file dir "b.jsonl"))
         (claude-transcript-speaker-function
          (lambda (_f) (list :name "RoleTest" :role "roletest")))
         (before (buffer-list))
         buffer)
    (cl-letf (((symbol-function 'claude-transcript--watch) #'ignore))
    (unwind-protect
        (progn
          (setq buffer (claude-transcript-buffer old))
          (should (eq buffer (claude-transcript-buffer new)))
          (should (equal (buffer-local-value 'claude-transcript--file buffer) new))
          (should (equal (buffer-name buffer) "*transcript: RoleTest*"))
          (should (= 1 (length (seq-filter
                                (lambda (b) (string-prefix-p "*transcript: RoleTest" (buffer-name b)))
                                (buffer-list))))))
      (dolist (b (seq-difference (buffer-list) before))
        (kill-buffer b))
      (delete-directory dir t)))))

(provide 'claude-transcript-role-test)
