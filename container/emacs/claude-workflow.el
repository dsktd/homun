;;; claude-workflow.el --- Workflow runs on the board and their run view -*- coding: utf-8; lexical-binding: t -*-

;; A Claude Code Workflow run keeps its agents under
;; <project>/<session>/subagents/workflows/<run>/agent-*.jsonl (+ .meta.json), next to a
;; journal.jsonl of `started' and `result' records, and its script under
;; <session>/workflows/scripts/<name>-<run>.js, whose `meta' names it and its phases.
;; Everything here is read from those files: no daemon, no state of its own.

(require 'homun-layout)
(require 'seq)
(require 'subr-x)
(require 'claude)
(require 'claude-agent)

(defvar claude-workflow-quiet-after 600
  "Seconds without a write to a run's files after which it is taken as ended.")

(defun claude-workflow--script (run)
  "The script file of the run directory RUN, or nil."
  (let* ((id (file-name-nondirectory (directory-file-name run)))
         (session (file-name-directory (directory-file-name
                                        (file-name-directory (directory-file-name
                                                              (file-name-directory (directory-file-name run))))))))
    (car (claude-agent-glob (expand-file-name (concat "workflows/scripts/*-" id ".js") session)))))

(defun claude-workflow--meta (script)
  "(NAME . PHASE-TITLES) from the `meta' of SCRIPT, a file or nil."
  (with-temp-buffer
    (when (and script (file-readable-p script))
      (insert-file-contents script nil 0 8192))
    (goto-char (point-min))
    (let ((name (and (re-search-forward "\\_<name: *['\"`]\\([^'\"`]+\\)" nil t) (match-string 1)))
          titles)
      (goto-char (point-min))
      (when (re-search-forward "\\_<phases *:" nil t)
        (while (re-search-forward "\\_<title: *['\"`]\\([^'\"`]+\\)" nil t)
          (push (match-string 1) titles)))
      (cons name (nreverse titles)))))

(defun claude-workflow--journal (run)
  "The agents the journal of RUN names, in start order: plists of :id :label :phase
:state."
  (let ((file (expand-file-name "journal.jsonl" run))
        agents)
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (while (not (eobp))
          (when-let* ((row (claude-agent--json-line))
                      ((listp row))
                      (id (alist-get 'agentId row)))
            (let ((agent (or (seq-find (lambda (a) (equal (plist-get a :id) id)) agents)
                             (car (push (list :id id :state 'running) agents))))
                  (type (alist-get 'type row)))
              (when-let* ((label (alist-get 'label row))) (plist-put agent :label label))
              (when-let* ((phase (alist-get 'phase row))) (plist-put agent :phase phase))
              (unless (equal type "started")
                (plist-put agent :state
                           (if (and (equal type "result") (not (alist-get 'error row)))
                               'done
                             'failed)))))
          (forward-line 1))))
    (nreverse agents)))

(defun claude-workflow--mtime (file)
  (if-let* ((attrs (file-attributes file)))
      (float-time (file-attribute-modification-time attrs))
    0))

(defun claude-workflow-run (run)
  "The task plist of the workflow run in directory RUN, or nil.
:phases is a list of (TITLE . AGENTS), AGENTS plists with :file as well."
  (let* ((journal (expand-file-name "journal.jsonl" run))
         (meta (claude-workflow--meta (claude-workflow--script run)))
         (agents (claude-workflow--journal run))
         (titles (cdr meta))
         (files (claude-agent-glob (expand-file-name "agent-*.jsonl" run)))
         (active (apply #'max (claude-workflow--mtime journal) (mapcar #'claude-workflow--mtime files)))
         (started (and files (seq-min (mapcar (lambda (f) (or (claude-agent--first-time f)
                                                                 (claude-workflow--mtime f)))
                                              files)))))
    (when (file-exists-p journal)
      (dolist (agent agents)
        (let ((file (expand-file-name (format "agent-%s.jsonl" (plist-get agent :id)) run)))
          (plist-put agent :file file)
          (unless (plist-get agent :label)
            (plist-put agent :label (alist-get 'description
                                               (claude-agent--json-file
                                                (concat (string-remove-suffix ".jsonl" file) ".meta.json")))))))
      (dolist (agent agents)
        (unless (member (plist-get agent :phase) titles)
          (setq titles (append titles (list (or (plist-get agent :phase) "?"))))))
      (let* ((phases (mapcar (lambda (title)
                               (cons title (seq-filter (lambda (a) (equal (plist-get a :phase) title))
                                                       agents)))
                             titles))
             (current (1+ (or (seq-position titles (plist-get (car (last agents)) :phase)) -1)))
             (done (seq-count (lambda (a) (eq (plist-get a :state) 'done)) agents))
             (live (and (< (- (float-time) active) claude-workflow-quiet-after)
                        (or (seq-find (lambda (a) (eq (plist-get a :state) 'running)) agents)
                            (< current (length titles))))))
        (list :kind 'workflow :run (file-name-as-directory run) :transcript journal
              :id (file-name-nondirectory (directory-file-name run))
              :name (or (car meta) "workflow") :phases phases
              :desc (format "⚙ %s · phase %d/%d · %d/%d agents"
                            (or (car meta) "workflow") current (length titles) done (length agents))
              :type "workflow" :started started :active active :running live)))))

(defun claude-workflow-runs (&optional days)
  "The workflow runs written to in the last DAYS days (default 1), as tasks."
  (let ((cutoff (- (float-time) (* (or days 1) 86400))))
    (seq-keep (lambda (run)
                (and (> (claude-workflow--mtime run) cutoff)
                     (claude-workflow-run run)))
              (seq-filter #'file-directory-p (claude-agent--glob "*/*/subagents/workflows/*")))))

;;; The run view

(defvar claude-workflow--buffer "*claude run*")
(defvar-local claude-workflow--run nil "The run directory this buffer shows.")
(defvar claude-workflow--timer nil)

(defconst claude-workflow--faces
  '((running . widgetry-status-pending) (done . widgetry-status-done) (failed . widgetry-status-failed)))

(declare-function claude-agent-view-open "claude-agent-view")

(defun claude-workflow--open-agent (button)
  (require 'claude-agent-view)
  (claude-agent-view-open (button-get button 'file)))

(defun claude-workflow--draw ()
  "Draw the run of this buffer: each phase with its counts, then its agents as
buttons."
  (let ((task (claude-workflow-run claude-workflow--run))
        (inhibit-read-only t)
        (line (line-number-at-pos)))
    (erase-buffer)
    (if (not task)
        (insert "The run is gone.\n")
      (insert (propertize (plist-get task :name) 'face 'bold)
              (propertize (format "  %s\n\n" (if (plist-get task :running) "running" "ended")) 'face 'shadow))
      (dolist (phase (plist-get task :phases))
        (let ((agents (cdr phase)))
          (insert (propertize (car phase) 'face 'bold) "  "
                  (propertize
                   (if agents
                       (mapconcat (lambda (state)
                                    (format "%d %s" (seq-count (lambda (a) (eq (plist-get a :state) state)) agents)
                                            state))
                                  (seq-filter (lambda (state) (seq-find (lambda (a) (eq (plist-get a :state) state)) agents))
                                              '(running done failed))
                                  " · ")
                     "not started")
                   'face 'shadow)
                  "\n")
          (dolist (agent agents)
            (let ((state (plist-get agent :state)))
              (insert "  " (propertize "●" 'face (alist-get state claude-workflow--faces)) " ")
              (insert-text-button (or (plist-get agent :label) (plist-get agent :id))
                                  'file (plist-get agent :file) 'action #'claude-workflow--open-agent
                                  'help-echo "Open this agent's work")
              (insert (propertize (format "  %s\n" state) 'face 'shadow))))
          (insert "\n"))))
    (goto-char (point-min))
    (forward-line (1- line))))

(define-derived-mode claude-workflow-mode special-mode "Claude-Run"
  "A workflow run: its phases and their agents."
  (setq truncate-lines t)
  (setq header-line-format (claude-header "Workflow run" "gr refresh | q quit"))
  (setq-local revert-buffer-function (lambda (&rest _) (claude-workflow--draw))))

(defun claude-workflow--tick ()
  (let ((buffer (get-buffer claude-workflow--buffer)))
    (cond ((not buffer) (cancel-timer claude-workflow--timer) (setq claude-workflow--timer nil))
          ((get-buffer-window buffer t)
           (with-current-buffer buffer
             (condition-case err (claude-workflow--draw)
               (error (message "claude-workflow: %s" (error-message-string err)))))))))

;;;###autoload
(defun claude-workflow-open (run)
  "Show the workflow run in directory RUN in the cockpit's side window."
  (require 'claude-todos)
  (let ((buffer (get-buffer-create claude-workflow--buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'claude-workflow-mode) (claude-workflow-mode))
      (setq claude-workflow--run run)
      (claude-workflow--draw))
    (homun-layout-side buffer)
    (unless claude-workflow--timer
      (setq claude-workflow--timer (run-at-time 2 2 #'claude-workflow--tick)))
    buffer))

(provide 'claude-workflow)
;;; claude-workflow.el ends here
