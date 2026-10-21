;;; claude-follow-test.el --- ERT for claude-follow.el -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-follow-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'claude-follow)

(defmacro claude-follow-test--with-dir (&rest body)
  `(let* ((claude-follow-dir (make-temp-file "follow" t))
          (claude-follow--entries nil)
          (claude-follow--hidden nil)
          (claude-follow--dones nil)
          (claude-follow--archive nil)
          (claude-follow-archive-after 1e12)
          (magit-section-visibility-cache nil))
     (when (get-buffer "*claude-follow*") (kill-buffer "*claude-follow*"))
     ;; the fixtures' projects (/w) are not on disk, which would archive them
     (cl-letf (((symbol-function 'claude-follow--project-gone-p) #'ignore))
       (unwind-protect (progn ,@body) (delete-directory claude-follow-dir t)))))

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
     (should (string-match-p "^  w$" (buffer-string)))
     (should (string-match-p "^    w (1)$" (buffer-string)))
     (should-not (string-match-p "own edits" (buffer-string)))
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

(ert-deftest claude-follow-keeps-only-usable-rows ()
  (claude-follow-test--with-dir
   (with-temp-file (expand-file-name "s1.jsonl" claude-follow-dir)
     (insert "{\"ts\":\"x\",\"session_id\":\"s1\",\"file\":\"/w/a\"}\n"
             "5\n[1,2]\n"
             "{\"ts\":1,\"session_id\":\"s1\",\"file\":5}\n"
             "{\"ts\":2,\"session_id\":\"s1\",\"agent\":7,\"file\":\"/w/b\"}\n"))
   (let ((rows (claude-follow--read)))
     (should (= 1 (length rows)))
     (should (equal "/w/b" (plist-get (car rows) :file)))
     (should (equal "main" (plist-get (car rows) :agent))))
   (with-current-buffer (claude-follow)
     (should (string-match-p "  b$" (buffer-string))))))

(ert-deftest claude-follow-applies-each-worktree-and-file-once ()
  (let (worktrees files)
    (cl-letf (((symbol-function 'claude-follow--refresh-worktree) (lambda (w) (push w worktrees)))
              ((symbol-function 'claude-follow--refresh-file) (lambda (f) (push f files))))
      (claude-follow--apply '((:file "/w/a" :worktree "/w") (:file "/w/b" :worktree "/w")
                              (:file "/w/a" :worktree "/w") (:file "/x" :worktree ""))))
    (should (equal worktrees '("/w")))
    (should (equal (sort files #'string<) '("/w/a" "/w/b" "/x")))))

(ert-deftest claude-follow-watch-events-coalesce ()
  (unwind-protect
      (progn
        (claude-follow--changed)
        (claude-follow--changed)
        (should (= 1 (seq-count (lambda (tm) (eq (timer--function tm) #'claude-follow--sync)) timer-list))))
    (cancel-timer claude-follow--sync-timer)))

(ert-deftest claude-follow-session-end-empties ()
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 1 "main" "/w/a")
   (delete-file (expand-file-name "s1.jsonl" claude-follow-dir))
   (should-not (claude-follow--read))))

(ert-deftest claude-follow-agent-count ()
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 1 "main" "/w/a")
   (claude-follow-test--log "s2" 2 "ag1" "/w/b")
   (should (= 1 (claude-follow-agent-count "ag1" nil)))
   (should (= 0 (claude-follow-agent-count "nobody" "none")))))

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

(defmacro claude-follow-test--visiting (text &rest body)
  "Run BODY in a buffer visiting a new file holding TEXT, bound as `file'."
  (declare (indent 1))
  `(let ((file (make-temp-file "cf")))
     (unwind-protect
         (with-temp-buffer
           (write-region ,text nil file)
           (insert-file-contents file)
           (set-visited-file-name file t t)
           (set-visited-file-modtime)
           ,@body)
       (delete-file file))))

(ert-deftest claude-follow-revert-picks-up-disk ()
  (claude-follow-test--visiting "one\ntwo\n"
    (write-region "one\nTWO\n" nil file)
    (claude-follow--revert)
    (should (equal "one\nTWO\n" (buffer-string)))))

(ert-deftest claude-follow-revert-leaves-a-current-buffer-alone ()
  (claude-follow-test--visiting "one\n"
    (let ((reverts 0))
      (cl-letf (((symbol-function 'revert-buffer) (lambda (&rest _) (cl-incf reverts))))
        (claude-follow--revert))
      (should (= 0 reverts)))))

(ert-deftest claude-follow-any-revert-records-the-change ()
  (let ((claude-follow-auto t))
    (claude-follow-test--visiting "one\ntwo\nthree\nfour\n"
      (write-region "one\nTWO\nTHREE\nfour\n" nil file)
      (revert-buffer t t t)             ; as auto-revert-mode would
      (should (equal '(5 14) (take 2 (claude-follow--recent-region)))))))

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
  "Press RET on the commit entry (status stubbed away, so a commit falls back to its diff); the arguments Magit gets, as (FN . ARGS)."
  (let (called)
    (cl-letf (((symbol-function 'magit-status-setup-buffer) #'ignore)
              ((symbol-function 'magit-get-mode-buffer) #'ignore)
              ((symbol-function 'magit-show-commit)
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

(ert-deftest claude-follow-commit-id-must-be-hex ()
  "A commit from the log is a git revision, so an option-like one is treated as unknown."
  (claude-follow-test--with-dir
   (claude-follow-test--commit-log "--output=/tmp/x")
   (should (equal '(log "/w/a" nil ("f.el")) (claude-follow-test--visit-commit)))))

(ert-deftest claude-follow-hunk-line ()
  (dolist (case '(("" . 1)
                  ("diff --git a/f b/f\n@@ -3,2 +7,4 @@ x\n+a\n" . 7)
                  ("@@ -0,0 +1 @@\n+a\n@@ -9 +12 @@\n" . 1)
                  ("@@ -5 +0,0 @@\n-a\n" . 1)
                  ("@@ -2,0 +4,3 @@\n@@ -9 +12 @@\n" . 4)))
    (should (= (cdr case) (claude-follow--hunk-line (car case))))))

(ert-deftest claude-follow-file-line-without-git ()
  (cl-letf (((symbol-function 'call-process)
             (lambda (&rest _) (signal 'file-missing '("Searching for program" "No such file" "git")))))
    (should (= 1 (claude-follow--file-line "/w/a" "/w")))))

(defvar claude-follow-test--evaluated nil)

(ert-deftest claude-follow-show-file-applies-no-unsafe-local-variables ()
  "A shown file is an agent's: its file-local variables must neither run nor ask."
  (let ((file (make-temp-file "cf" nil ".el" ";; -*- eval: (setq claude-follow-test--evaluated t) -*-\n"))
        asked)
    (unwind-protect
        (cl-letf (((symbol-function 'claude-follow--display) (lambda (&rest _) (selected-window)))
                  ((symbol-function 'claude-follow--file-line) (lambda (&rest _) 1))
                  ((symbol-function 'read-char-choice) (lambda (&rest _) (setq asked t) ?n)))
          (let ((noninteractive nil))   ; the daemon's case: files.el only skips the ask in batch
            (claude-follow--show-file file "/w"))
          (should (find-buffer-visiting file))
          (should-not asked)
          (should-not claude-follow-test--evaluated))
      (when-let* ((b (find-buffer-visiting file))) (kill-buffer b))
      (delete-file file))))

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

(ert-deftest claude-follow-show-magit-reaches-magits-display-variables ()
  "Magit is not loaded here, as in a daemon that has not used it yet; the
bindings must still be dynamic, else Magit would select its window."
  (should (eq #'claude-follow--display
              (claude-follow--show-magit (lambda () (symbol-value 'magit-display-buffer-function)))))
  (should (claude-follow--show-magit (lambda () (symbol-value 'magit-display-buffer-noselect)))))

(ert-deftest claude-follow-workspace-of-file ()
  (let ((home (expand-file-name "~/claude")))
    (should (equal "roles" (claude-follow--workspace-of (concat home "/roles/claude-wrapper/a.el"))))
    (should (equal "_tools" (claude-follow--workspace-of (concat home "/_tools/dotfiles/x/y"))))
    (should (equal "claude" (claude-follow--workspace-of (concat home "/CLAUDE.md"))))
    (should (equal "srv" (claude-follow--workspace-of "/srv/elsewhere/a")))))

(ert-deftest claude-follow-merges-agents-under-a-project ()
  (claude-follow-test--with-dir
   (let ((home (expand-file-name "~/claude")))
     (with-temp-file (expand-file-name "s1.jsonl" claude-follow-dir)
       (dolist (agent '(("claude" "" 1) ("abcdefghij" "impl" 2)))
         (insert (format "{\"ts\":%d,\"session_id\":\"s1\",\"agent\":\"%s\",\"agent_type\":\"%s\",\"tool\":\"Edit\",\"file\":\"%s/ws/r/%s\",\"worktree\":\"%s/ws/r\"}\n"
                         (nth 2 agent) (car agent) (cadr agent) home (car agent) home))))
     (with-current-buffer (claude-follow)
       (let ((text (buffer-string)))
         (should (string-match-p "^  ws$" text))
         (should (= 1 (with-temp-buffer (insert text) (how-many "^    r (2)$" (point-min)))))
         (should (string-match-p "abcdefghij  impl abcdefg$" text))
         (should (string-match-p "claude$" text))
         (should-not (string-match-p "claude  agent" text)))))))

(ert-deftest claude-follow-toggle-leaves-other-buffers-alone ()
  (let ((claude-follow-auto t))
    (with-temp-buffer
      (insert "keep me")
      (claude-follow-toggle-auto)
      (should (equal "keep me" (buffer-string)))
      (should-not claude-follow-auto))))

(ert-deftest claude-follow-hides-a-session ()
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 1 "main" "/w/a")
   (claude-follow-test--log "s2" 2 "main" "/w/b")
   (claude-follow)
   (should (= 1 (claude-follow--hide '((session "s1")) 10)))
   (should (equal '("/w/b") (mapcar (lambda (e) (plist-get e :file)) claude-follow--entries)))
   (with-current-buffer (get-buffer "*claude-follow*")
     (should-not (string-match-p "Session s1" (car (split-string (buffer-string) "Archive (")))))))

(ert-deftest claude-follow-hides-a-project-and-a-workspace ()
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 1 "main" "/w/a")
   (claude-follow-test--log "s2" 2 "ag" "/w/b")
   (claude-follow-test--log "s3" 3 "main" "/w/c")
   (claude-follow-refresh)
   (should (= 3 (claude-follow--hide '((project "/w")) 10)))
   (setq claude-follow--hidden nil)
   (claude-follow-refresh)
   (should (= 1 (claude-follow--hide '((workspace "s2" "w")) 10)))
   (should (= 2 (length claude-follow--entries)))))

(ert-deftest claude-follow-hides-all ()
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 1 "main" "/w/a")
   (claude-follow-test--log "s2" 2 "main" "/w/b")
   (claude-follow-refresh)
   (cl-letf (((symbol-function 'float-time) (lambda (&rest _) 10)))
     (claude-follow-hide-all))
   (should-not claude-follow--entries)))

(ert-deftest claude-follow-newer-entries-reappear ()
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 5 "main" "/w/a")
   (claude-follow-refresh)
   (claude-follow--hide '((session "s1")) 10)
   (should-not claude-follow--entries)
   (claude-follow-test--log "s1" 11 "main" "/w/c")
   (claude-follow-refresh)
   (should (equal '("/w/c") (mapcar (lambda (e) (plist-get e :file)) claude-follow--entries)))))

(ert-deftest claude-follow-show-all-restores ()
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 1 "main" "/w/a")
   (claude-follow-refresh)
   (claude-follow--hide '((session "s1")) 10)
   (claude-follow-show-all)
   (should (= 1 (length claude-follow--entries)))))

(ert-deftest claude-follow-counts-exclude-hidden ()
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 1 "main" "/w/a")
   (claude-follow-test--log "s2" 2 "ag1" "/w/b")
   (claude-follow-refresh)
   (claude-follow--hide '((session "s2")) 10)
   (should (= 0 (claude-follow-agent-count "ag1" nil)))))

(ert-deftest claude-follow-x-hides-the-section-at-point ()
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 1 "main" "/w/a")
   (claude-follow-test--log "s2" 2 "main" "/w/b")
   (with-current-buffer (claude-follow)
     (goto-char (point-min))
     (claude-follow-next-edit)
     (should (equal '(project "/w") (claude-follow--key-at-point)))
     (magit-section-up)
     (should (equal '(project "/w") (claude-follow--key-at-point)))
     (magit-section-up)
     (should (equal '(workspace "s2" "w") (claude-follow--key-at-point)))
     (claude-follow-hide)
     (should (= 1 (length claude-follow--entries))))))

(defun claude-follow-test--done (session ts agent)
  (with-temp-buffer
    (insert (format "{\"ts\":%d,\"session_id\":\"%s\",\"agent\":\"%s\",\"agent_type\":\"impl\",\"tool\":\"done\",\"file\":\"\",\"cwd\":\"\",\"worktree\":\"\"}\n"
                    ts session agent))
    (write-region nil nil (expand-file-name (concat session ".jsonl") claude-follow-dir) t 'silent)))

(ert-deftest claude-follow-done-rows-are-not-edits ()
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 1 "ag1" "/w/a")
   (claude-follow-test--done "s1" 2 "ag1")
   (claude-follow-test--done "s9" 3 "ag9")
   (should (equal '("/w/a") (mapcar (lambda (e) (plist-get e :file)) (claude-follow--read))))
   (should (= 1 (claude-follow-agent-count "ag1" nil)))
   (let ((claude-follow-max-entries 1))
     (should (equal '("/w/a") (mapcar (lambda (e) (plist-get e :file)) (claude-follow--read)))))
   (with-current-buffer (claude-follow)
     (should-not (string-match-p "s9" (buffer-string))))))

(defmacro claude-follow-test--shown (&rest body)
  "Run BODY, return the worktrees shown as Magit status."
  `(let (shown)
     (cl-letf (((symbol-function 'claude-follow--show-status) (lambda (w) (push w shown))))
       ,@body)
     (nreverse shown)))

(ert-deftest claude-follow-fresh-done-shows-that-agents-projects-once ()
  (claude-follow-test--with-dir
   (let ((claude-follow-display 'file) (claude-follow-auto t))
     (claude-follow-test--log "s1" 1 "ag1" "/w/a")
     (claude-follow-test--done "s1" 2 "ag1")      ; old, before the first load
     (should-not (claude-follow-test--shown (claude-follow-refresh) (claude-follow--sync)))
     (claude-follow-test--done "s1" 5 "ag2")      ; an agent with no edits
     (claude-follow-test--done "s1" 6 "ag1")
     (should (equal '("/w") (claude-follow-test--shown (claude-follow--sync))))
     (should-not (claude-follow-test--shown (claude-follow--sync))))))

(ert-deftest claude-follow-done-needs-the-toggle-display-and-auto ()
  (dolist (off '(claude-follow-status-on-done claude-follow-display claude-follow-auto))
    (claude-follow-test--with-dir
     (let ((claude-follow-display 'file) (claude-follow-auto t) (claude-follow-status-on-done t))
       (claude-follow-test--log "s1" 1 "ag1" "/w/a")
       (claude-follow-refresh)
       (claude-follow-test--done "s1" 6 "ag1")
       (set off nil)
       (should-not (claude-follow-test--shown (claude-follow--sync)))))))

(ert-deftest claude-follow-maps-a-done-row-to-its-projects ()
  (let ((claude-follow--entries '((:session "s1" :agent "main" :worktree "/a")
                                  (:session "s1" :agent "ag1" :worktree "/b")
                                  (:session "s2" :agent "ag1" :worktree "/c")
                                  (:session "s1" :agent "ag1" :worktree ""))))
    (should (equal '("/b") (claude-follow--projects-of '(:session "s1" :agent "ag1"))))
    (should-not (claude-follow--projects-of '(:session "s1" :agent "nobody")))))

(ert-deftest claude-follow-toggles-status-on-done ()
  (let ((claude-follow-status-on-done t))
    (claude-follow-toggle-status-on-done)
    (should-not claude-follow-status-on-done)
    (claude-follow-toggle-status-on-done)
    (should claude-follow-status-on-done)))

(ert-deftest claude-follow-status-needs-a-project-at-point ()
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 1 "main" "/w/a")
   (let (shown)
     (cl-letf (((symbol-function 'claude-follow--show-status) (lambda (w) (push w shown))))
       (with-current-buffer (claude-follow)
         (goto-char (point-min))
         (claude-follow-next-edit)
         (claude-follow-status)                 ; an edit line
         (magit-section-up)
         (claude-follow-status)                 ; the project heading
         (should (equal '("/w" "/w") shown))
         (magit-section-up)                     ; the workspace heading
         (claude-follow-status)
         (magit-section-up)                     ; the session heading
         (claude-follow-status)
         (should (equal '("/w" "/w") shown)))))))

(defun claude-follow-test--heading-face (text)
  (save-excursion
    (goto-char (point-min))
    (search-forward-regexp (concat "^ +\\(" text "\\)"))
    (get-text-property (match-beginning 1) 'font-lock-face)))

(defun claude-follow-test--heading (text)
  "The (STRING . FACE) of the heading line matching TEXT."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward (concat "^ +\\(" text "\\)"))
    (cons (match-string-no-properties 1) (get-text-property (match-beginning 1) 'font-lock-face))))

(defun claude-follow-test--log-file (file worktree)
  (with-temp-file (expand-file-name "s1.jsonl" claude-follow-dir)
    (insert (format "{\"ts\":1,\"session_id\":\"s1\",\"file\":\"%s\",\"worktree\":\"%s\"}\n" file worktree))))

(ert-deftest claude-follow-treebundel-headings-have-no-emoji-and-their-faces ()
  (claude-follow-test--with-dir
   (let ((home (expand-file-name "~")))
     (claude-follow-test--log-file (concat home "/claude/ws/r/f") (concat home "/claude/ws/r"))
     (with-current-buffer (claude-follow)
       (should (equal '("ws" . magit-section-secondary-heading) (claude-follow-test--heading "ws$")))
       (should (equal '("r (1)" . magit-branch-local) (claude-follow-test--heading "r (1)")))
       (cl-letf (((symbol-function 'facep)
                  (lambda (f) (memq f '(treebundel-workspace treebundel-project)))))
         (claude-follow-refresh))
       (should (equal '("ws" . treebundel-workspace) (claude-follow-test--heading "ws$")))
       (should (equal '("r (1)" . treebundel-project) (claude-follow-test--heading "r (1)")))))))

(ert-deftest claude-follow-outside-headings-have-an-emoji-and-one-face ()
  (let ((home (expand-file-name "~")))
    (dolist (case `((,(concat home "/.claude/x") "dotfiles" "\\.claude")
                    ("/tmp/claude-0/x" "tmp" "claude-0")
                    ("/srv/a/b" "srv" "a")))
      (claude-follow-test--with-dir
       (claude-follow-test--log-file (nth 0 case) "")
       (with-current-buffer (claude-follow)
         (let ((workspace (claude-follow-test--heading (concat (nth 1 case) "$")))
               (project (claude-follow-test--heading (concat (nth 2 case) " (1)"))))
           (should (eq 'claude-follow-outside (cdr workspace)))
           (should (eq 'claude-follow-outside (cdr project)))
           ;; keys and section values carry no emoji
           (let ((key (progn (goto-char (point-min)) (claude-follow-next-edit) (claude-follow--key-at-point))))
             (should (equal 'project (car key)))
             (should (stringp (cadr key))))))))))

(ert-deftest claude-follow-dotfiles-workspace-and-project ()
  (let ((home (expand-file-name "~")))
    (dolist (case `((,(concat home "/.claude/x/y") "" "dotfiles" ,(concat home "/.claude"))
                    (,(concat home "/.bashrc") "" "dotfiles" ,(concat home "/.bashrc"))
                    (,(concat home "/claude/ws/repo/f") ,(concat home "/claude/ws/repo") "ws"
                     ,(concat home "/claude/ws/repo"))
                    (,(concat home "/claude/ws/loose") "" "ws" ,(concat home "/claude/ws"))
                    (,(concat home "/claude/CLAUDE.md") "" "claude" ,(concat home "/claude"))
                    (,(concat home "/claude/ws/d/f.el") "" "ws" ,(concat home "/claude/ws/d"))
                    ("/tmp/claude-0/x/y.txt" "" "tmp" "/tmp/claude-0")
                    ("/tmp/claude-0/f" "" "tmp" "/tmp/claude-0")
                    ("/tmp/f" "" "tmp" "/tmp")
                    ("/srv/a/b" "" "srv" "/srv/a")))
      (let ((entry (claude-follow--entry (list :ts 1 :file (nth 0 case) :worktree (nth 1 case)))))
        (should (equal (nth 2 case) (plist-get entry :workspace)))
        (should (equal (nth 3 case) (plist-get entry :project)))))
    (should (equal "x/y" (claude-follow--relative (concat home "/.claude/x/y") (concat home "/.claude"))))
    (should (equal "x/y.txt" (claude-follow--relative "/tmp/claude-0/x/y.txt" "/tmp/claude-0")))
    (should (equal ".bashrc" (claude-follow--relative (concat home "/.bashrc") (concat home "/.bashrc"))))))

(ert-deftest claude-follow-hides-only-one-dotfiles-project ()
  (claude-follow-test--with-dir
   (let ((home (expand-file-name "~")))
     (with-temp-file (expand-file-name "s1.jsonl" claude-follow-dir)
       (insert (format "{\"ts\":2,\"session_id\":\"s1\",\"file\":\"%s/.claude/f\"}\n" home)
               (format "{\"ts\":1,\"session_id\":\"s1\",\"file\":\"%s/.config/f\"}\n" home)))
     (with-current-buffer (claude-follow)
       (should (string-match-p "^    \\.claude (1)$" (buffer-string)))
       (goto-char (point-min))
       (claude-follow-next-edit)
       (let ((key (claude-follow--key-at-point)))
         (should (eq 'project (car key)))
         (claude-follow-hide)
         (should (= 1 (length claude-follow--entries)))
         (should-not (string-match-p "\\.claude" (car (split-string (buffer-string) "Archive ("))))
         (should (string-match-p "\\.config" (buffer-string))))))))

(defun claude-follow-test--project-hidden-p ()
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "^    w (")
    (oref (magit-current-section) hidden)))

(ert-deftest claude-follow-projects-start-collapsed-and-stay-as-left ()
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 1 "main" "/w/a")
   (with-current-buffer (claude-follow)
     (should (claude-follow-test--project-hidden-p))
     (goto-char (point-min))
     (re-search-forward "^    w (")
     (magit-section-show (magit-current-section))
     (claude-follow-refresh)
     (should-not (claude-follow-test--project-hidden-p))
     (claude-follow-test--log "s1" 2 "main" "/w/b")
     (claude-follow--sync)
     (should-not (claude-follow-test--project-hidden-p)))))

(ert-deftest claude-follow-next-edit-opens-a-collapsed-project ()
  (claude-follow-test--with-dir
   (claude-follow-test--log "s1" 1 "main" "/w/a")
   (with-current-buffer (claude-follow)
     (goto-char (point-min))
     (claude-follow-next-edit)
     (should (equal "/w/a" (claude-follow--file-at-point)))
     (should-not (claude-follow-test--project-hidden-p)))))
