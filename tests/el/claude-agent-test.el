;;; claude-agent-test.el --- ERT for claude-agent.el -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-agent-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'claude-agent)
(require 'claude-dashboard)

(defun claude-agent-test--transcript (dir)
  "Write a transcript with a cut first line, a malformed line and two tool calls."
  (let ((file (expand-file-name "t.jsonl" dir)))
    (with-temp-file file
      (insert "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Old\"}]}}\n"
              "not json\n"
              "[1,2]\n"
              "{\"type\":\"assistant\",\"timestamp\":\"2026-10-20T10:00:00Z\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Read\",\"input\":{\"file_path\":\"/w/a.el\"}}]}}\n"
              "{\"type\":\"assistant\",\"timestamp\":\"2026-10-20T10:01:00Z\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"first\"},{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"echo hello\\nsecond line\"}}]}}\n"
              "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"latest words\"}]}}\n"))
    file))

(ert-deftest claude-agent-tail-parses-tools-and-text ()
  (let* ((dir (make-temp-file "agent" t))
         (file (claude-agent-test--transcript dir)))
    (unwind-protect
        (let ((tail (claude-agent--tail file)))
          (should (equal (mapcar #'cadr (plist-get tail :tools)) '("Bash" "Read" "Old")))
          (should (equal (nth 2 (car (plist-get tail :tools))) "echo hello"))
          (should (equal (nth 2 (cadr (plist-get tail :tools))) "/w/a.el"))
          (should (equal (plist-get tail :text) "latest words")))
      (delete-directory dir t))))

(ert-deftest claude-agent-tail-skips-cut-first-line ()
  (let* ((dir (make-temp-file "agent" t))
         (file (claude-agent-test--transcript dir))
         (claude-agent-tail-bytes 330))
    (unwind-protect
        (should-not (member "Old" (mapcar #'cadr (plist-get (claude-agent--tail file) :tools))))
      (delete-directory dir t))))

(defmacro claude-agent-test--with-db (&rest body)
  `(let* ((dir (make-temp-file "agentdb" t))
          (claude-agent-db (expand-file-name "u.sqlite" dir))
          (db (sqlite-open claude-agent-db)))
     (unwind-protect
         (progn
           (sqlite-execute db "create table messages (id, ts, session_id, agent_id, model, input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens)")
           (sqlite-execute db "create view message_costs as select *, input_tokens * 1.0 / 1000000 cost_usd from messages")
           (sqlite-execute db "create table agent_runs (session_id, name, kind, cwd, started_at, state, last_seen, pid)")
           (sqlite-execute db "create table events (ts, source, kind, detail, session_id)")
           (sqlite-execute db "insert into messages values ('a', 1, 's', null, 'opus', 10, 5, 2, 8)")
           (sqlite-execute db "insert into messages values ('b', 2, 's', 'x1', 'sonnet', 1000000, 7, 0, 0)")
           (sqlite-execute db "insert into messages values ('c', 3, 's', 'x1', 'sonnet', 1000000, 1, 0, 0)")
           (sqlite-execute db "insert into events values (5, 'agents', 'done', 'job', 's')")
           (sqlite-close db)
           ,@body)
       (delete-directory dir t))))

(ert-deftest claude-agent-usage-by-agent-id ()
  (claude-agent-test--with-db
   (should (equal (claude-agent--usage '(:session "s" :id "x1")) '(2 2000000 8 0 0 2.0 "sonnet")))
   (should (equal (claude-agent--usage '(:session "s")) '(1 10 5 2 8 1e-05 "opus")))
   (should-not (claude-agent--usage '(:session "other")))
   (should (equal (cadr (claude-agent--states '(:session "s"))) '((5 "done" "job"))))))

(ert-deftest claude-agent-first-time-and-subagent-usage ()
  (let* ((dir (make-temp-file "agent" t))
         (file (claude-agent-test--transcript dir)))
    (unwind-protect
        (should (= (claude-agent--first-time file) (float-time (date-to-time "2026-10-20T10:00:00Z"))))
      (delete-directory dir t)))
  (claude-agent-test--with-db
   (with-temp-buffer
     (claude-agent--insert-usage '(:kind subagent :session "s" :id "x1"))
     (should (string-match-p "2 messages" (buffer-string)))
     (should-not (string-match-p "done" (buffer-string))))
   (with-temp-buffer
     (claude-agent--insert-usage '(:kind session :session "s"))
     (should (string-match-p "done" (buffer-string))))))

(ert-deftest claude-agent-missing-database-is-one-error ()
  (let ((claude-agent-db "/nonexistent/u.sqlite"))
    (should-error (claude-agent--usage '(:session "s")) :type 'claude-agent-error)))

(ert-deftest claude-agent-buffer-for-worker-and-unknown ()
  (let* ((dir (make-temp-file "agentw" t))
         (claude-agent-workers dir)
         (claude-agent-db "/nonexistent/u.sqlite")
         (claude-follow-dir (expand-file-name "follow" dir)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "w1" dir))
          (with-temp-file (expand-file-name "w1/result.txt" dir) (insert "ok"))
          (with-temp-file (expand-file-name "ledger.jsonl" dir)
            (insert "{\"name\":\"w1\",\"agent\":\"researcher\",\"model\":\"sonnet\",\"exit\":0,\"ts\":1}\n"))
          (with-current-buffer (claude-agent-show "w1" "claude-worker run")
            (should (equal (buffer-name) "*claude-agent: w1*"))
            (should (string-match-p "State: +done" (buffer-string)))
            (should (string-match-p "result.txt" (buffer-string)))
            (should (string-match-p "All edits: \\*claude-follow\\*" (buffer-string)))
            (kill-buffer)))
      (delete-directory dir t))))

(ert-deftest claude-agent-dashboard-dispatch ()
  (let (called)
    (cl-letf (((symbol-function 'claude-agent-show) (lambda (&rest args) (setq called args))))
      (with-temp-buffer
        (claude-dashboard-mode)
        (let ((inhibit-read-only t))
          (magit-insert-section (root)
            (magit-insert-section (claude-agent "agent My job (impl subagent)")
              (insert "My job\n"))))
        (goto-char (point-min))
        (claude-dashboard-visit)))
    (should (equal called '("My job" "impl subagent")))))

(provide 'claude-agent-test)
;;; claude-agent-test.el ends here
