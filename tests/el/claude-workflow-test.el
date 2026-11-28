;;; claude-workflow-test.el --- ERT for workflow runs on the board -*- lexical-binding: t -*-

(require 'ert)
(require 'claude-board)
(require 'claude-workflow)

(defmacro claude-workflow-test--with (&rest body)
  "Run BODY with `run' a fixture run directory under a fake projects dir."
  (declare (indent 0))
  `(let* ((root (make-temp-file "claude-wf" t))
          (claude-agent-projects root)
          (session (expand-file-name "proj/s1/" root))
          (run (expand-file-name "subagents/workflows/wf_1/" session)))
     (unwind-protect
         (progn
           (make-directory run t)
           (make-directory (expand-file-name "workflows/scripts" session) t)
           (with-temp-file (expand-file-name "workflows/scripts/demo-wf_1.js" session)
             (insert "export const meta = {\n  name: 'demo',\n  phases: [\n"
                     "    { title: 'Map', detail: 'x' },\n    { title: 'Judge', detail: 'y' },\n  ],\n}\n"))
           (with-temp-file (expand-file-name "journal.jsonl" run)
             (insert "{\"type\":\"launched\"}\n"
                     "{\"type\":\"started\",\"agentId\":\"a1\",\"label\":\"map:a\",\"phase\":\"Map\"}\n"
                     "{\"type\":\"started\",\"agentId\":\"a2\",\"label\":\"map:b\",\"phase\":\"Map\"}\n"
                     "{\"type\":\"result\",\"agentId\":\"a1\",\"result\":{}}\n"))
           (dolist (id '("a1" "a2"))
             (with-temp-file (expand-file-name (format "agent-%s.jsonl" id) run) (insert "{}\n"))
             (with-temp-file (expand-file-name (format "agent-%s.meta.json" id) run)
               (insert "{\"description\":\"d\",\"inWorkflowRun\":true}")))
           ,@body)
       (delete-directory root t))))

(ert-deftest claude-workflow-run-reads-phases-and-states ()
  (claude-workflow-test--with
    (let ((task (claude-workflow-run run)))
      (should (equal (plist-get task :desc) "⚙ demo · phase 1/2 · 1/2 agents"))
      (should (plist-get task :running))
      (should (equal (mapcar #'car (plist-get task :phases)) '("Map" "Judge")))
      (should (equal (mapcar (lambda (a) (plist-get a :state)) (cdar (plist-get task :phases)))
                     '(done running))))))

(ert-deftest claude-workflow-board-nests-agents-under-run ()
  (claude-workflow-test--with
    (let* ((main (list :kind 'main :desc "M" :transcript (expand-file-name "proj/s1.jsonl" root)))
           (agents (mapcar (lambda (f) (claude-tasks--subagent f))
                           (directory-files run t "\\.meta\\.json\\'")))
           (rows (claude-board--tree (append (list main (claude-workflow-run run)) agents))))
      (should (equal (claude-board--session-of (car agents)) "s1"))
      (should (equal (mapcar (lambda (r) (plist-get r :desc)) rows)
                     '("M" "└ ⚙ demo · phase 1/2 · 1/2 agents" "  ├ d" "  └ d"))))))

(ert-deftest claude-workflow-view-lists-agents ()
  (claude-workflow-test--with
    (with-current-buffer (claude-workflow-open run)
      (should (string-match-p "Map  1 running · 1 done" (buffer-string)))
      (should (string-match-p "Judge  not started" (buffer-string))))))
