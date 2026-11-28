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

(ert-deftest claude-agent-activity-waits-for-the-transcript ()
  (with-temp-buffer
    (claude-agent--insert-activity '(:transcript "/nonexistent/agent-1.jsonl"))
    (should (string-empty-p (buffer-string)))))

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
        (org-mode)
        (insert (claude-dashboard--agent-link "My job" "impl subagent"))
        (goto-char (point-min))
        (org-open-at-point)))
    (should (equal called '("My job" "impl subagent")))))

(provide 'claude-agent-test)
;;; claude-agent-test.el ends here

;;; The cached glob

(defun claude-agent-test--tree ()
  "A temporary projects tree, its directory times well in the past."
  (let ((root (make-temp-file "agent-glob" t)))
    (dolist (file '("p1/a.jsonl" "p1/b.jsonl" "p2/c.jsonl" "p1/a/subagents/agent-x.meta.json"
                    "p2/c/subagents/workflows/w1/journal.jsonl" "p1/.hidden.jsonl"))
      (let ((path (expand-file-name file root)))
        (make-directory (file-name-directory path) t)
        (write-region "{}" nil path nil 'silent)))
    (claude-agent-test--age root)
    root))

(defun claude-agent-test--age (root)
  "Set every directory under ROOT, ROOT included, an hour into the past."
  (let ((old (time-subtract nil 3600)))
    (dolist (dir (cons root (seq-filter #'file-directory-p (directory-files-recursively root "" t))))
      (set-file-times dir old))))

(ert-deftest claude-agent-glob-matches-file-expand-wildcards ()
  (let* ((root (claude-agent-test--tree))
         (claude-agent--listings (make-hash-table :test #'equal)))
    (unwind-protect
        (dolist (pattern '("*/*.jsonl" "*/*/subagents" "*/*/subagents/workflows/*"
                           "*/*/subagents/agent-*.meta.json" "p1/a.jsonl" "p9/*" "*/a"))
          ;; Dot files are left out, as the board never wants them
          (should (equal (sort (seq-remove (lambda (f) (string-prefix-p "." (file-name-nondirectory f)))
                                           (file-expand-wildcards (expand-file-name pattern root)))
                               #'string<)
                         (claude-agent-glob (expand-file-name pattern root)))))
      (delete-directory root t))))

(ert-deftest claude-agent-glob-rereads-a-changed-directory ()
  "A listing is kept while its directory's mtime holds and read again once it moves."
  (let* ((root (claude-agent-test--tree))
         (claude-agent--listings (make-hash-table :test #'equal))
         (pattern (expand-file-name "*/*.jsonl" root)))
    (unwind-protect
        (progn
          (should (= 3 (length (claude-agent-glob pattern))))
          (write-region "{}" nil (expand-file-name "p2/d.jsonl" root) nil 'silent)
          (claude-agent-test--age root)
          ;; Same mtime as at the read: kept, even though a name was added
          (set-file-times (expand-file-name "p2" root) (car (gethash (expand-file-name "p2" root)
                                                                     claude-agent--listings)))
          (should (= 3 (length (claude-agent-glob pattern))))
          (claude-agent-test--age root)
          (set-file-times (expand-file-name "p2" root) (time-subtract nil 60))
          (should (= 4 (length (claude-agent-glob pattern)))))
      (delete-directory root t))))

(ert-deftest claude-agent-glob-does-not-keep-a-fresh-listing ()
  "A directory changed within the settle time is read again on every call."
  (let* ((root (claude-agent-test--tree))
         (claude-agent--listings (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (set-file-times (expand-file-name "p1" root))
          (claude-agent-glob (expand-file-name "*/*" root))
          (should-not (gethash (expand-file-name "p1" root) claude-agent--listings))
          (should (gethash root claude-agent--listings)))
      (delete-directory root t))))

(ert-deftest claude-agent-newest-stats-each-file-once ()
  (let* ((root (claude-agent-test--tree))
         (files (claude-agent-glob (expand-file-name "*/*.jsonl" root)))
         (stats 0))
    (unwind-protect
        (progn
          (set-file-times (expand-file-name "p1/b.jsonl" root) (time-add nil 60))
          (advice-add 'file-attributes :before (lambda (&rest _) (cl-incf stats)) '((name . count)))
          (unwind-protect
              (should (equal (expand-file-name "p1/b.jsonl" root) (claude-agent-newest files)))
            (advice-remove 'file-attributes 'count))
          (should (= stats (length files))))
      (delete-directory root t))))
