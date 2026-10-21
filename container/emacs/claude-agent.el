;;; claude-agent.el --- Everything about one Claude agent in a buffer -*- lexical-binding: t -*-

;; `claude-agent-show' opens `*claude-agent: NAME*' (one per agent, reused): header lines, usage
;; from usage-db, recent activity from the transcript, the agent's edits (as in `claude-follow')
;; and a link to `*claude-follow*'.  Read-only everywhere: the database is opened with
;; `query_only', transcripts are parsed as data and never run.  Every failure is one
;; `claude-agent-error', shown in the section that hit it.

(require 'cl-lib)
(require 'claude-follow)
(require 'json)
(require 'magit-section)
(require 'seq)
(require 'subr-x)

(define-error 'claude-agent-error "Claude agent")

(defvar claude-agent-projects "~/.claude/projects"
  "Where Claude Code keeps transcripts: <project>/<session>.jsonl and <session>/subagents/.")

(defvar claude-agent-db "~/claude/.services/usage-db/usage.sqlite"
  "The usage database (`messages', `message_costs', `agent_runs', `events').")

(defvar claude-agent-workers "~/claude/.services/workers"
  "The claude-worker directory: <name>/ files and ledger.jsonl.")

(defvar claude-agent-tail-bytes 200000
  "How much of the end of a transcript is read.")

(defvar claude-agent-interval 10
  "Seconds between refreshes of a visible buffer whose agent is running.")

(defvar-local claude-agent--args nil "The (NAME INFO) this buffer shows.")
(defvar-local claude-agent--timer nil)
(defvar-local claude-agent--running nil "Whether the agent was running at the last draw.")
(defvar-local claude-agent--transcript nil)

;;; Finding the agent

(defun claude-agent--glob (pattern)
  (file-expand-wildcards (expand-file-name pattern claude-agent-projects)))

(defun claude-agent--json-file (file)
  "FILE parsed as one JSON object (alist), or nil."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents file)
      (json-parse-buffer :object-type 'alist :array-type 'list))))

(defun claude-agent--session-transcript (session)
  (car (claude-agent--glob (concat "*/" session ".jsonl"))))

(defun claude-agent--subagent (name)
  "The newest subagent whose description or id is NAME, as a plist, or nil."
  (let (best)
    (dolist (meta (claude-agent--glob "*/*/subagents/agent-*.meta.json"))
      (let* ((info (claude-agent--json-file meta))
             (transcript (concat (file-name-sans-extension (file-name-sans-extension meta)) ".jsonl"))
             (id (string-remove-prefix "agent-" (file-name-base transcript))))
        (when (and info (or (equal (alist-get 'description info) name) (equal id name)))
          (let ((time (file-attribute-modification-time (file-attributes transcript))))
            (when (or (null best) (time-less-p (plist-get best :mtime) time))
              (setq best (list :mtime time :id id :transcript transcript
                               :session (file-name-nondirectory
                                         (directory-file-name
                                          (file-name-directory (directory-file-name (file-name-directory meta)))))
                               :type (alist-get 'agentType info) :model (alist-get 'model info)
                               :description (alist-get 'description info)
                               :state (if (eq (alist-get 'finished info) t) "done" "busy"))))))))
    best))

(defun claude-agent--listed (name)
  "The entry of `claude agents --json --all' called or with id NAME, as a plist, or nil."
  (ignore-errors
    (with-temp-buffer
      (call-process "timeout" nil '(t nil) nil "20" "claude" "agents" "--json" "--all")
      (goto-char (point-min))
      (when-let* ((found (seq-find (lambda (a) (or (equal (alist-get 'name a) name)
                                                   (equal (alist-get 'id a) name)))
                                   (json-parse-buffer :object-type 'alist :array-type 'list))))
        (list :session (alist-get 'sessionId found) :cwd (alist-get 'cwd found)
              :state (alist-get 'state found) :description (alist-get 'name found)
              :started (and (alist-get 'startedAt found) (/ (alist-get 'startedAt found) 1000)))))))

(defun claude-agent--worker-row (name)
  "The last ledger row of the worker NAME, or nil."
  (let ((ledger (expand-file-name "ledger.jsonl" claude-agent-workers)) row)
    (when (file-readable-p ledger)
      (with-temp-buffer
        (insert-file-contents ledger)
        (dolist (line (split-string (buffer-string) "\n" t))
          (when-let* ((r (condition-case nil (json-parse-string line :object-type 'alist)
                           (json-parse-error nil))))
            (when (equal (alist-get 'name r) name) (setq row r))))))
    row))

(defun claude-agent--resolve (name info)
  "A plist describing the agent NAME whose dashboard INFO is the text in parentheses."
  (let ((info (or info "")))
    (cond
     ((string-prefix-p "claude-worker" info)
      (let ((row (claude-agent--worker-row name)))
        (list :kind 'worker :name name :row row
              :state (cond ((null row) "unknown") ((null (alist-get 'exit row)) "busy")
                           ((eql (alist-get 'exit row) 0) "done") (t "failed"))
              :model (alist-get 'model row) :type (alist-get 'agent row)
              :started (alist-get 'ts row))))
     ((equal name claude-follow-manager-name)
      (let ((session (claude-follow--manager-session)))
        (list :kind 'session :name name :session session :state (car (split-string info))
              :transcript (and session (claude-agent--session-transcript session)))))
     ((string-match-p "subagent" info)
      (let ((sub (claude-agent--subagent name)))
        (append (list :kind 'subagent :name name) sub)))
     (t
      (let ((listed (claude-agent--listed name)))
        (append (list :kind 'session :name name :state (car (split-string info)))
                listed
                (and (plist-get listed :session)
                     (list :transcript (claude-agent--session-transcript (plist-get listed :session))))))))))

(defun claude-agent--json-line ()
  "The current line parsed as JSON (alists, lists), or nil when it is not JSON."
  (condition-case nil
      (json-parse-string (buffer-substring (point) (line-end-position))
                         :object-type 'alist :array-type 'list)
    (json-parse-error nil)))

(defun claude-agent--first-time (file)
  "Epoch seconds of the first parseable entry with a timestamp in transcript FILE, or nil."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents file nil 0 20000)
      (catch 'found
        (while (not (eobp))
          (let* ((rec (claude-agent--json-line))
                 (ts (and (listp rec) (alist-get 'timestamp rec))))
            (when (stringp ts) (throw 'found (float-time (date-to-time ts)))))
          (forward-line 1))))))

(defun claude-agent--running-p (agent)
  (not (member (plist-get agent :state) '("done" "failed" "stopped" "unknown"))))

;;; Usage

(defun claude-agent--select (sql &rest values)
  "Rows of SQL with VALUES bound, from the usage database opened read-only."
  (unless (and (fboundp 'sqlite-available-p) (sqlite-available-p))
    (signal 'claude-agent-error '("this Emacs has no SQLite")))
  (let ((file (expand-file-name claude-agent-db)))
    (unless (file-readable-p file) (signal 'claude-agent-error (list (format "no database %s" file))))
    (condition-case err
        (let ((db (sqlite-open file)))
          (unwind-protect
              (progn (sqlite-execute db "pragma query_only = 1")
                     (sqlite-select db sql values))
            (sqlite-close db)))
      (sqlite-error (signal 'claude-agent-error (list (format "database: %s" (cdr err))))))))

(defun claude-agent--where (agent)
  "SQL condition and values selecting AGENT's rows in `messages'."
  (if (plist-get agent :id)
      (list "session_id = ? and agent_id = ?" (plist-get agent :session) (plist-get agent :id))
    (list "session_id = ? and agent_id is null" (plist-get agent :session))))

(defun claude-agent--usage (agent)
  "(MESSAGES INPUT OUTPUT CACHE-WRITE CACHE-READ COST MODEL) for AGENT, or nil without messages."
  (let* ((w (claude-agent--where agent))
         (row (car (apply #'claude-agent--select
                          (concat "select count(*), sum(input_tokens), sum(output_tokens),"
                                  " sum(cache_creation_input_tokens), sum(cache_read_input_tokens),"
                                  " sum(cost_usd), (select model from messages where " (car w)
                                  " order by ts desc limit 1) from message_costs where " (car w))
                          (append (cdr w) (cdr w))))))
    (and row (> (car row) 0) row)))

(defun claude-agent--states (agent)
  "(RUNS EVENTS) of the session of AGENT: `agent_runs' rows and the newest `events'."
  (let ((s (plist-get agent :session)))
    (list (claude-agent--select "select name, kind, state, started_at, last_seen from agent_runs where session_id = ?" s)
          (claude-agent--select "select ts, kind, detail from events where session_id = ? order by ts desc limit 10" s))))

;;; Transcript

(defun claude-agent--target (input)
  "A short target for a tool call with the INPUT alist."
  (let ((value (or (alist-get 'file_path input) (alist-get 'path input) (alist-get 'pattern input)
                   (alist-get 'url input) (alist-get 'command input) (alist-get 'description input))))
    (and (stringp value) (truncate-string-to-width (car (split-string value "\n")) 60 nil nil "..."))))

(defun claude-agent--tail (file)
  "(:tools ((TIME NAME TARGET) ...) :text STRING) from the end of the transcript FILE.
Tools are newest first, at most 15.  Malformed lines are skipped."
  (let (tools text)
    (with-temp-buffer
      (let* ((size (file-attribute-size (file-attributes file)))
             (start (max 0 (- size claude-agent-tail-bytes))))
        (insert-file-contents file nil start size)
        (when (> start 0) (forward-line 1)))
      (while (not (eobp))
        (let* ((rec (claude-agent--json-line))
               (message (and (listp rec) (alist-get 'message rec)))
               (content (and (listp message) (equal (alist-get 'type rec) "assistant")
                             (alist-get 'content message))))
          (when (listp content)
            (dolist (item content)
              (when (listp item)
                (pcase (alist-get 'type item)
                  ("tool_use" (push (list (alist-get 'timestamp rec) (alist-get 'name item)
                                          (and (listp (alist-get 'input item))
                                               (claude-agent--target (alist-get 'input item))))
                                    tools))
                  ("text" (when (stringp (alist-get 'text item))
                            (setq text (alist-get 'text item)))))))))
        (forward-line 1)))
    (list :tools (seq-take tools 15) :text text)))

;;; Drawing

(defun claude-agent--time (ts)
  "TS (epoch seconds or ISO string) as local `MM-DD HH:MM:SS'."
  (condition-case nil
      (format-time-string "%m-%d %H:%M:%S" (if (numberp ts) ts (date-to-time ts)))
    (error "?")))

(defun claude-agent--line (label value)
  (when value
    (insert (propertize (format "%-9s" (concat label ":")) 'font-lock-face 'magit-section-heading)
            (format "%s" value) "\n")))

(defun claude-agent--note (text)
  (insert (propertize (concat text "\n") 'font-lock-face 'shadow)))

(defun claude-agent--insert-header (agent)
  (magit-insert-section (claude-agent-header)
    (claude-agent--line (if (eq (plist-get agent :kind) 'worker) "Worker" "Agent")
                        (concat (plist-get agent :name)
                                (and (plist-get agent :type) (format " (%s)" (plist-get agent :type)))))
    (claude-agent--line "Id" (or (plist-get agent :id)
                                 (and (eq (plist-get agent :kind) 'session) "main agent of the session")))
    (claude-agent--line "State" (plist-get agent :state))
    (claude-agent--line "Model" (plist-get agent :model))
    (when-let* ((started (plist-get agent :started)))
      (claude-agent--line "Started"
                          (format "%s (%s ago)" (claude-agent--time started)
                                  (format-seconds "%hh %mm" (max 0 (- (float-time) started))))))
    (claude-agent--line "Session" (plist-get agent :session))
    (claude-agent--line "Cwd" (and (plist-get agent :cwd) (abbreviate-file-name (plist-get agent :cwd))))
    (claude-agent--line "About" (plist-get agent :description))
    (unless (or (plist-get agent :id) (plist-get agent :session) (eq (plist-get agent :kind) 'worker))
      (claude-agent--note "No session or transcript found for this agent."))
    (insert "\n")))

(defun claude-agent--insert-usage (agent)
  (when (plist-get agent :session)
    (let ((usage (claude-agent--usage agent))
          (states (unless (eq (plist-get agent :kind) 'subagent) (claude-agent--states agent))))
      (when (or usage (car states) (cadr states))
        (magit-insert-section (claude-agent-usage)
          (magit-insert-heading "Usage")
          (when usage
            (pcase-let ((`(,n ,in ,out ,write ,read ,cost ,model) usage))
              (let ((all (+ (or in 0) (or write 0) (or read 0))))
                (insert (format "  %d messages  in %d  out %d  cache write %d  read %d  (%.0f%% hits)  $%.2f%s\n"
                                n (or in 0) (or out 0) (or write 0) (or read 0)
                                (if (> all 0) (* 100.0 (/ (or read 0) (float all))) 0)
                                (or cost 0) (if model (concat "  " model) ""))))))
          (dolist (run (car states))
            (insert (format "  run: %s  %s  %s  started %s  seen %s\n" (nth 0 run) (nth 1 run) (nth 2 run)
                            (claude-agent--time (nth 3 run)) (claude-agent--time (nth 4 run)))))
          (dolist (event (cadr states))
            (insert (format "  %s  %s  %s\n" (claude-agent--time (nth 0 event)) (nth 1 event) (nth 2 event))))
          (insert "\n"))))))

(defun claude-agent--insert-activity (agent)
  "The last tool calls and text of AGENT's transcript; nothing before the file exists."
  (when-let* ((file (plist-get agent :transcript))
              ((file-readable-p file)))
    (let ((tail (claude-agent--tail file)))
      (when (or (plist-get tail :tools) (plist-get tail :text))
        (magit-insert-section (claude-agent-activity)
          (magit-insert-heading "Activity")
          (dolist (tool (plist-get tail :tools))
            (insert "  " (propertize (claude-agent--time (nth 0 tool)) 'font-lock-face 'shadow)
                    "  " (nth 1 tool) (if (nth 2 tool) (concat "  " (nth 2 tool)) "") "\n"))
          (when-let* ((text (plist-get tail :text)))
            (insert (propertize "\n  Latest progress: " 'font-lock-face 'magit-section-heading)
                    (truncate-string-to-width (replace-regexp-in-string "\n" " " text) 400 nil nil "...")
                    "\n"))
          (insert "\n"))))))

(defun claude-agent--insert-worker (agent)
  (let* ((name (plist-get agent :name))
         (dir (expand-file-name name claude-agent-workers)))
    (magit-insert-section (claude-agent-worker)
      (magit-insert-heading "Worker")
      (dolist (cell (plist-get agent :row))
        (insert (format "  %-11s %s\n" (car cell) (cdr cell))))
      (unless (plist-get agent :row) (claude-agent--note "  No ledger row."))
      (dolist (file (and (file-directory-p dir) (directory-files dir t "\\`[^.]" t)))
        (magit-insert-section (claude-agent-file file)
          (insert (format "  %-12s %d bytes\n" (file-name-nondirectory file)
                          (file-attribute-size (file-attributes file))))))
      (insert "\n"))))

(defun claude-agent--entries (agent)
  (let ((entries (claude-follow--agent-entries (plist-get agent :name) (plist-get agent :type))))
    (if (plist-get agent :id)
        (seq-filter (lambda (e) (equal (plist-get e :agent) (plist-get agent :id))) entries)
      entries)))

(defun claude-agent--insert-edits (agent)
  (when-let* ((entries (claude-agent--entries agent)))
    (magit-insert-section (claude-agent-edits)
      (magit-insert-heading "Edits")
      (let ((claude-follow--expand-projects t))
        (dolist (tree (claude-follow--group entries :project))
          (claude-follow--insert-project (car tree) (cdr tree) nil t)))))
  (magit-insert-section (claude-agent-link)
    (insert "All edits: " (propertize "*claude-follow*" 'font-lock-face 'link) "\n")))

(defmacro claude-agent--section (&rest body)
  "Run BODY; a `claude-agent-error' becomes a note instead."
  `(condition-case err (progn ,@body)
     (claude-agent-error (claude-agent--note (format "  %s" (error-message-string err))))))

(defun claude-agent--draw ()
  "Redraw the current buffer from `claude-agent--args'."
  (let* ((agent (apply #'claude-agent--resolve claude-agent--args))
         (agent (if (or (plist-get agent :started) (not (plist-get agent :transcript)))
                    agent
                  (plist-put agent :started (claude-agent--first-time (plist-get agent :transcript)))))
         (section (magit-current-section))
         (position (and section (magit-section-get-relative-position section)))
         (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (claude-agent-root)
      (claude-agent--insert-header agent)
      (if (eq (plist-get agent :kind) 'worker)
          (claude-agent--insert-worker agent)
        (claude-agent--section (claude-agent--insert-usage agent))
        (claude-agent--section (claude-agent--insert-activity agent)))
      (claude-agent--insert-edits agent))
    (goto-char (point-min))
    (when section (apply #'magit-section-goto-successor section position))
    (setq-local claude-agent--running (claude-agent--running-p agent)
                claude-agent--transcript (plist-get agent :transcript))))

;;; Commands

(defun claude-agent-refresh ()
  "Read everything again and redraw."
  (interactive)
  (claude-agent--draw))

(defun claude-agent-visit ()
  "Open what is at point: `*claude-follow*', a worker file, or as in `claude-follow'."
  (interactive)
  (let ((section (magit-current-section)))
    (pcase (and section (oref section type))
      ('claude-agent-link (pop-to-buffer (claude-follow)))
      ('claude-agent-file (pop-to-buffer (find-file-noselect (oref section value))))
      (_ (claude-follow-visit)))))

(defun claude-agent-transcript ()
  "Open the transcript read-only."
  (interactive)
  (if (and claude-agent--transcript (file-readable-p claude-agent--transcript))
      (pop-to-buffer (let ((buffer (find-file-noselect claude-agent--transcript)))
                       (with-current-buffer buffer (read-only-mode 1))
                       buffer))
    (user-error "No transcript for this agent")))

(defvar claude-agent-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "g") #'claude-agent-refresh)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "t") #'claude-agent-transcript)
    (define-key map (kbd "RET") #'claude-agent-visit)
    (define-key map (kbd "d") #'claude-follow-diff)
    (define-key map (kbd "D") #'claude-follow-difftastic)
    (define-key map (kbd "l") #'claude-follow-log)
    map))

(define-derived-mode claude-agent-mode magit-section-mode "Claude-Agent"
  "Everything about one Claude agent: usage, activity and edits.")

(declare-function evil-define-key "evil-core")
(with-eval-after-load 'evil
  (evil-define-key '(normal motion) claude-agent-mode-map
    (kbd "gr") #'claude-agent-refresh
    (kbd "q") #'quit-window
    (kbd "t") #'claude-agent-transcript
    (kbd "RET") #'claude-agent-visit
    (kbd "TAB") #'magit-section-toggle)
  (claude-follow--bind-folds claude-agent-mode-map)
  (claude-follow--bind-leader
   'claude-agent-mode claude-agent-mode-map
   '(("d" . claude-follow-diff) ("D" . claude-follow-difftastic) ("l" . claude-follow-log))))

(defun claude-agent--tick (buffer)
  "Redraw BUFFER when it is visible and its agent runs."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and claude-agent--running (get-buffer-window buffer t))
        (claude-agent--draw)))))

(defun claude-agent--start-timer ()
  "Refresh this buffer every `claude-agent-interval' seconds until it is killed."
  (unless claude-agent--timer
    (let ((timer (run-at-time claude-agent-interval claude-agent-interval
                              #'claude-agent--tick (current-buffer))))
      (setq claude-agent--timer timer)
      (add-hook 'kill-buffer-hook (lambda () (cancel-timer timer)) nil t))))

;;;###autoload
(defun claude-agent-show (name info)
  "Open the buffer about the agent NAME; INFO is the text in parentheses on its dashboard line."
  (let ((buffer (get-buffer-create (format "*claude-agent: %s*" name))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'claude-agent-mode) (claude-agent-mode))
      (setq claude-agent--args (list name info))
      (claude-agent--draw)
      (unless noninteractive (claude-agent--start-timer)))
    (if noninteractive (set-buffer buffer) (pop-to-buffer buffer))
    buffer))

(provide 'claude-agent)

;;; claude-agent.el ends here
