;;; claude-follow-test.el --- ERT for claude-follow.el -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-follow-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'claude-follow)

(defmacro claude-follow-test--with-dir (&rest body)
  `(let* ((claude-follow-dir (make-temp-file "follow" t))
          (claude-follow--entries nil))
     (unwind-protect (progn ,@body) (delete-directory claude-follow-dir t))))

(defun claude-follow-test--log (session ts agent file)
  (with-temp-file (expand-file-name (concat session ".jsonl") claude-follow-dir)
    (insert (format "{\"ts\":%d,\"session_id\":\"%s\",\"agent\":\"%s\",\"agent_type\":\"\",\"tool\":\"Edit\",\"file\":\"%s\",\"worktree\":\"/w\"}\n"
                    ts session agent file))))

(ert-deftest claude-follow-reads-and-caps ()
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 1 "main" "/w/a")
   (claude-follow-test--log "s2" 2 "ag" "/w/b")
   (should (equal (mapcar (lambda (e) (plist-get e :file)) (claude-follow--read)) '("/w/b" "/w/a")))
   (let ((claude-follow-max-entries 1))
     (should (= 1 (length (claude-follow--read)))))))

(ert-deftest claude-follow-draws-sections ()
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 1 "main" "/w/a")
   (with-current-buffer (claude-follow)
     (should (string-match-p "Session s1" (buffer-string)))
     (should (string-match-p "^  own edits$" (buffer-string)))
     (should (string-match-p "^      [0-9:]+  a$" (buffer-string)))
     (goto-char (point-min))
     (claude-follow-next-edit)
     (should (equal "/w/a" (claude-follow--file-at-point))))))

(ert-deftest claude-follow-detects-new-edits ()
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 1 "main" "/w/a")
   (let ((old (claude-follow--read)))
     (claude-follow-test--log "s1" 5 "main" "/w/c")
     (delete-file (expand-file-name "s1.jsonl" claude-follow-dir))
     (claude-follow-test--log "s1" 1 "main" "/w/a")
     (should-not (claude-follow--new old (claude-follow--read))))))

(ert-deftest claude-follow-session-end-empties ()
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 1 "main" "/w/a")
   (delete-file (expand-file-name "s1.jsonl" claude-follow-dir))
   (should-not (claude-follow--read))))

(ert-deftest claude-follow-agent-link ()
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 1 "main" "/w/a")
   (claude-follow-test--log "s2" 2 "ag1" "/w/b")
   (should (= 1 (claude-follow-agent-count "ag1" nil)))
   (should (= 0 (claude-follow-agent-count "nobody" "none")))
   (with-current-buffer (claude-follow)
     (claude-follow-show-agent "ag1" nil)
     (should (equal "/w/b" (claude-follow--file-at-point))))))

(ert-deftest claude-follow-worktree-at-point ()
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 1 "main" "/w/a")
   (with-current-buffer (claude-follow)
     (goto-char (point-min))
     (claude-follow-next-edit)
     (should (equal "/w" (claude-follow--worktree-at-point))))))

(ert-deftest claude-follow-dashboard-agent-line ()
  (require 'claude-dashboard)
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 1 "main" "/w/a")
   (should (= 1 (claude-dashboard--edits "main" "running")))))

(ert-deftest claude-follow-revert-picks-up-disk ()
  (let ((file (make-temp-file "cf")))
    (unwind-protect
        (with-temp-buffer
          (write-region "one\ntwo\n" nil file)
          (insert-file-contents file)
          (set-visited-file-name file t t)
          (write-region "one\nTWO\n" nil file)
          (claude-follow--revert)
          (should (equal "one\nTWO\n" (buffer-string))))
      (delete-file file))))

(ert-deftest claude-follow-any-revert-records-the-change ()
  (let ((file (make-temp-file "cf"))
        (claude-follow-auto t))
    (unwind-protect
        (with-temp-buffer
          (write-region "one\ntwo\nthree\nfour\n" nil file)
          (insert-file-contents file)
          (set-visited-file-name file t t)
          (write-region "one\nTWO\nTHREE\nfour\n" nil file)
          (revert-buffer t t t)         ; as auto-revert-mode would
          (should (equal '(5 14) (take 2 (claude-follow--recent-region)))))
      (delete-file file))))

(ert-deftest claude-follow-manager-is-named ()
  (let ((file (make-temp-file "cf")))
    (unwind-protect
        (let ((claude-follow-manager-session-file file))
          (write-region "sess-1\n" nil file)
          (should (claude-follow--manager-p "sess-1"))
          (should-not (claude-follow--manager-p "sess-2"))
          (should (claude-follow--main-p "claude"))
          (should-not (claude-follow--main-p "agent-9")))
      (delete-file file))))

(defun claude-follow-test--commit-log (commit)
  (with-temp-file (expand-file-name "s1.jsonl" claude-follow-dir)
    (insert (format "{\"ts\":1,\"session_id\":\"s1\",\"agent\":\"main\",\"tool\":\"commit\",\"file\":\"/w/a/f.el\",\"worktree\":\"/w/a\",\"commit\":\"%s\"}\n"
                    commit))))

(defun claude-follow-test--visit-commit ()
  "Press RET on the commit entry; the arguments Magit gets, as (FN . ARGS)."
  (let (called)
    (cl-letf (((symbol-function 'magit-show-commit)
               (lambda (&rest args) (setq called (cl-list* 'show default-directory args))))
              ((symbol-function 'magit-log-current)
               (lambda (&rest args) (setq called (cl-list* 'log default-directory args)))))
      (with-current-buffer (claude-follow)
        (goto-char (point-min))
        (claude-follow-next-edit)
        (claude-follow-visit)))
    called))

(ert-deftest claude-follow-commit-entry-shows-commit ()
  (claude-follow-test--with-dir
   (claude-follow-test--commit-log "abcdef0123456")
   (should (string-match-p "^      [0-9:]+  f.el abcdef0$" (with-current-buffer (claude-follow) (buffer-string))))
   (should (equal '(show "/w/a" "abcdef0123456" nil ("f.el")) (claude-follow-test--visit-commit)))))

(ert-deftest claude-follow-commit-entry-without-id-shows-log ()
  (claude-follow-test--with-dir
   (claude-follow-test--commit-log "")
   (should (equal '(log "/w/a" nil ("f.el")) (claude-follow-test--visit-commit)))))

(ert-deftest claude-follow-hunk-line ()
  (dolist (case '(("" . 1)
                  ("diff --git a/f b/f\n@@ -3,2 +7,4 @@ x\n+a\n" . 7)
                  ("@@ -0,0 +1 @@\n+a\n@@ -9 +12 @@\n" . 1)
                  ("@@ -5 +0,0 @@\n-a\n" . 1)
                  ("@@ -2,0 +4,3 @@\n@@ -9 +12 @@\n" . 4)))
    (should (= (cdr case) (claude-follow--hunk-line (car case))))))

(ert-deftest claude-follow-cycles-display ()
  (let ((claude-follow-display 'file))
    (claude-follow-cycle-display) (should (eq claude-follow-display 'diff))
    (claude-follow-cycle-display) (should-not claude-follow-display)
    (claude-follow-cycle-display) (should (eq claude-follow-display 'file))
    (should (eq (lookup-key claude-follow-mode-map "v") #'claude-follow-cycle-display))))

(ert-deftest claude-follow-show-needs-gui-and-mode ()
  (let ((shown nil)
        (entry '(:file "/w/a/f.el" :worktree "/w/a" :tool "Edit" :commit "")))
    (cl-letf (((symbol-function 'claude-follow--show-file) (lambda (&rest _) (setq shown t)))
              ((symbol-function 'claude-follow--show-magit) (lambda (&rest _) (setq shown t))))
      (let ((claude-follow-display 'file))
        (claude-follow--show entry)
        (should-not shown)
        (cl-letf (((symbol-function 'claude-follow--gui-frame) (lambda () t)))
          (claude-follow--show entry)
          (should shown)
          (setq shown nil)
          (let ((claude-follow-display nil))
            (claude-follow--show entry)
            (should-not shown)))))))

(ert-deftest claude-follow-workspace-from-cwd ()
  (let ((home (expand-file-name "~/claude")))
    (should (equal "roles" (claude-follow--workspace (list (list :cwd (concat home "/roles/claude-wrapper"))))))
    (should (equal "_tools" (claude-follow--workspace (list (list :cwd (concat home "/_tools/dotfiles"))))))
    (should-not (claude-follow--workspace (list (list :cwd home))))
    (should (equal "elsewhere" (claude-follow--workspace (list (list :cwd "/srv/elsewhere")))))
    (should-not (claude-follow--workspace (list (list :cwd "")))))
  ;; the oldest entry's cwd wins (entries are newest first)
  (should (equal "a" (claude-follow--workspace
                      (list (list :cwd (expand-file-name "~/claude/b/x"))
                            (list :cwd (expand-file-name "~/claude/a/x")))))))

(ert-deftest claude-follow-toggle-leaves-other-buffers-alone ()
  (let ((claude-follow-auto t))
    (with-temp-buffer
      (insert "keep me")
      (claude-follow-toggle-auto)
      (should (equal "keep me" (buffer-string)))
      (should-not claude-follow-auto))))
