;;; claude-transcript-past-test.el --- search over past sessions -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-transcript-past-test.el -f ert-run-tests-batch-and-exit
(require 'ert)
(require 'claude-transcript-past)

(defconst past-test--old "11111111-1111-1111-1111-111111111111")
(defconst past-test--new "22222222-2222-2222-2222-222222222222")
(defconst past-test--other "33333333-3333-3333-3333-333333333333")

(defun past-test--user (text time)
  (format "{\"type\":\"user\",\"timestamp\":\"%s\",\"message\":{\"role\":\"user\",\"content\":%S}}\n" time text))

(defun past-test--assistant (blocks time)
  (format "{\"type\":\"assistant\",\"timestamp\":\"%s\",\"message\":{\"id\":\"m\",\"content\":%s}}\n" time blocks))

(defun past-test--setup ()
  "A state directory with a start.log and a project directory; return (STATE . PROJECT)."
  (let* ((state (make-temp-file "state" t)) (project (make-temp-file "proj" t)))
    (make-directory (expand-file-name "roletest" state))
    (with-temp-file (expand-file-name "roletest/start.log" state)
      (insert (format "1.0 role-pin: session resume (%s)\n2.0 start.sh: rotating %s to %s\n"
                      past-test--old past-test--old past-test--new)))
    (with-temp-file (expand-file-name (concat past-test--old ".jsonl") project)
      (insert (past-test--user "first about zebras" "2026-11-01T10:00:00Z")
              (past-test--assistant "[{\"type\":\"text\",\"text\":\"zebras are striped\"}]" "2026-11-01T10:00:01Z")
              (past-test--assistant "[{\"type\":\"tool_use\",\"id\":\"t\",\"name\":\"Bash\",\"input\":{\"command\":\"echo zebras\"}}]" "2026-11-01T10:00:02Z")
              (past-test--user "second turn" "2026-11-01T10:01:00Z")
              (past-test--assistant "[{\"type\":\"text\",\"text\":\"plain answer\"}]" "2026-11-01T10:01:01Z")
              (past-test--user "third turn" "2026-11-01T10:02:00Z")))
    (with-temp-file (expand-file-name (concat past-test--new ".jsonl") project)
      (insert (past-test--user "new session" "2026-11-20T10:00:00Z")))
    ;; a session of someone else in the same directory is never searched
    (with-temp-file (expand-file-name (concat past-test--other ".jsonl") project)
      (insert (past-test--user "zebras elsewhere" "2026-11-02T10:00:00Z")))
    (cons state project)))

(ert-deftest claude-transcript-past-ids-and-files ()
  (let* ((dirs (past-test--setup))
         (claude-transcript-past-state-directory (car dirs)))
    (should (equal (claude-transcript-past--ids "roletest")
                   (list past-test--old past-test--new)))
    (should-not (claude-transcript-past--ids "norole"))
    (should (= 2 (length (claude-transcript-past--files "roletest" (cdr dirs)))))))

(ert-deftest claude-transcript-past-hits-text-only ()
  "A tool's input does not count as something said."
  (let* ((line (past-test--assistant "[{\"type\":\"tool_use\",\"id\":\"t\",\"name\":\"Bash\",\"input\":{\"command\":\"echo zebras\"}}]" "2026-11-01T10:00:02Z")))
    (should (claude-transcript-search--hits line 0 "zebras"))
    (should-not (claude-transcript-search--hits line 0 "zebras" t))))

(ert-deftest claude-transcript-past-search-and-view ()
  (skip-unless (executable-find "rg"))
  (let* ((dirs (past-test--setup))
         (claude-transcript-past-state-directory (car dirs))
         (claude-transcript-speaker-function nil)
         (before (buffer-list)))
    (unwind-protect
        (let ((transcript (generate-new-buffer "*past-test-transcript*")))
          (with-current-buffer transcript
            (setq claude-transcript--role "roletest"
                  claude-transcript--file (expand-file-name (concat past-test--new ".jsonl") (cdr dirs))))
          (with-current-buffer transcript (claude-transcript-past "zebras"))
          (let ((results (get-buffer "*past: roletest*")))
            (with-current-buffer results
              (while (process-live-p claude-transcript-past--process)
                (accept-process-output claude-transcript-past--process 1))
              (accept-process-output nil 0.1)
              ;; the user's prompt and the assistant's text, not the tool input, not the other session
              (should (= 2 claude-transcript-past--count))
              (should (string-match-p "2026-11-01 .*zebras" (buffer-string)))
              (goto-char (point-min))
              (let ((hit (get-text-property (line-beginning-position) 'claude-transcript-past-hit)))
                (should (equal (plist-get hit :who) "You"))
                (claude-transcript-past-visit))
              (let ((view (current-buffer)))
                (should (derived-mode-p 'claude-transcript-mode))
                (should (string-match-p "first about zebras" (buffer-string)))
                (should (string-match-p "second turn" (buffer-string)))
                (should-not (string-match-p "third turn" (buffer-string)))
                (should-not (string-match-p "new session" (buffer-string)))
                (should buffer-read-only)
                (let ((dir (file-name-directory claude-transcript--file)))
                  (kill-buffer view)
                  (should-not (file-exists-p dir)))))))
      (dolist (b (seq-difference (buffer-list) before)) (kill-buffer b))
      (delete-directory (car dirs) t)
      (delete-directory (cdr dirs) t))))

(provide 'claude-transcript-past-test)
