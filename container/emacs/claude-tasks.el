;;; claude-tasks.el --- Readers of running subagents, jobs and workers -*- coding: utf-8; lexical-binding: t -*-

;; The disk readers behind `claude-board' (the one list of running work):
;; subagents from the meta files under ~/.claude/projects (sessions touched in
;; the last two days), jobs, watch runs and claude-worker calls.  Disk only;
;; no model is involved.  `claude-tasks--stop' appends a `tasks-stop' request
;; to the scheduler events and the manager acts on it; nothing is killed here.

(declare-function claude-bus-tell "claude-bus")
(require 'claude)
(require 'claude-agent)
(require 'json)
(require 'seq)
(require 'subr-x)

(defvar claude-tasks-session-days 2
  "Only sessions modified within this many days are read.")
(defvar claude-tasks-jobs-dir (expand-file-name "~/claude/.services/jobs/running/")
  "Where `claude-job' entries are.")
(defvar claude-tasks-watch-dir (expand-file-name "~/claude/.services/watch/runs/")
  "Where `homun watch' run records are.")
(defvar claude-tasks-ledger (expand-file-name "~/claude/.services/workers/ledger.jsonl")
  "The claude-worker ledger.")
(defvar claude-tasks-events (expand-file-name "~/claude/.services/scheduler/events")
  "The scheduler's event queue.")

;;; Reading

(defun claude-tasks--secs (time)
  "Return TIME, a time value, as epoch seconds."
  (float-time time))

(defun claude-tasks--subagent (meta)
  "Return the task plist of the subagent whose meta file is META, or nil."
  (when-let* ((info (claude-agent--json-file meta))
              (transcript (concat (string-remove-suffix ".meta.json" meta) ".jsonl"))
              (attrs (file-attributes transcript)))
    (list :kind 'subagent
          :id (string-remove-prefix "agent-" (file-name-base transcript))
          :desc (or (alist-get 'description info) "")
          :type (alist-get 'agentType info)
          :model (or (alist-get 'model info) (alist-get 'pickedEffortModel info))
          :started (claude-agent--first-time transcript)
          :active (claude-tasks--secs (file-attribute-modification-time attrs))
          :running (not (eq (alist-get 'finished info) t))
          :run (and (alist-get 'inWorkflowRun info) (file-name-directory transcript))
          :transcript transcript)))

(defun claude-tasks--subagents ()
  "Return the subagent tasks of recently modified sessions.
The subagents directories are globbed first and only the recent ones are
searched for meta files, so old sessions cost one stat each."
  (let ((cutoff (- (float-time) (* claude-tasks-session-days 86400))))
    (seq-keep
     #'claude-tasks--subagent
     (seq-mapcat
      (lambda (dir)
        (and (> (claude-tasks--secs (file-attribute-modification-time (file-attributes dir))) cutoff)
             (claude-agent-glob (expand-file-name "agent-*.meta.json" dir))))
      (append (claude-agent--glob "*/*/subagents")
              (claude-agent--glob "*/*/subagents/workflows/*"))))))

(defun claude-tasks--json-files (dir)
  "Return the parsed JSON objects of the .json files in DIR."
  (seq-keep #'claude-agent--json-file
            (and (file-directory-p dir) (directory-files dir t "\\.json\\'"))))

(defun claude-tasks--simple (kind rows name-key)
  "Return running task plists of KIND from the alists ROWS, named by NAME-KEY."
  (mapcar (lambda (row)
            (let ((since (or (alist-get 'since row) (alist-get 'ts row))))
              (list :kind kind :running t :id (format "%s" (alist-get name-key row))
                    :desc (format "%s" (or (alist-get name-key row) kind))
                    :type (symbol-name kind) :model (alist-get 'model row)
                    :started (and (numberp since) since)
                    :active (and (numberp since) since))))
          rows))

(defun claude-tasks--jobs ()
  "Return the running `claude-job' entries as tasks."
  (claude-tasks--simple 'job (claude-tasks--json-files claude-tasks-jobs-dir) 'name))

(defun claude-tasks--watches ()
  "Return the `homun watch' runs in state running as tasks."
  (claude-tasks--simple
   'watch
   (seq-filter (lambda (row) (equal (alist-get 'state row) "running"))
               (claude-tasks--json-files claude-tasks-watch-dir))
   'name))

(defun claude-tasks--workers ()
  "Return the claude-worker ledger rows with a null exit as tasks."
  (let (rows)
    (when (file-readable-p claude-tasks-ledger)
      (with-temp-buffer
        (insert-file-contents claude-tasks-ledger)
        (while (not (eobp))
          (when-let* ((row (claude-agent--json-line)))
            (when (and (listp row) (null (alist-get 'exit row)))
              (push row rows)))
          (forward-line 1))))
    (claude-tasks--simple 'worker (nreverse rows) 'name)))

;;; Background tasks of a session
;; Shell commands and agents a session left running in the background are not
;; on disk anywhere this Emacs can see, so they are read from the session's own
;; transcript: a tool result with `backgroundTaskId' starts a shell job, one with
;; status `async_launched' an agent, and a `task-notification' entry ends either.
;; The file is read incrementally: only the bytes added since the last call, and
;; only the lines that can matter are parsed.

(defvar claude-tasks-sessions-dir (expand-file-name "~/.claude/sessions/")
  "Where Claude Code keeps one <pid>.json per running session process.")

(defvar claude-tasks--background (make-hash-table :test #'equal)
  "Transcript FILE -> (OFFSET TASKS CALLS): the bytes read so far, a hash table
of task id to plist, and one of tool use id to (DESCRIPTION . COMMAND).")

(defconst claude-tasks--background-regexp
  "backgroundTaskId\\|async_launched\\|task-notification\\|\"run_in_background\""
  "What a transcript line has to contain to be parsed at all.")

(defun claude-tasks--iso (string)
  "Epoch seconds of the ISO 8601 STRING, or nil."
  (and (stringp string) (ignore-errors (float-time (date-to-time string)))))

(defun claude-tasks--xml (text tag)
  "The text of the first <TAG> element of TEXT, or nil."
  (when (string-match (format "<%s>\\(\\(?:.\\|\n\\)*?\\)</%s>" tag tag) text)
    (match-string 1 text)))

(defun claude-tasks--task-id (prompt)
  "The id on the first `task: ID' line of PROMPT, an agent's brief, or nil."
  (and (stringp prompt)
       (let ((case-fold-search t))
         (string-match "^[ \t]*task:[ \t]*\\([^ \t\n]+\\)[ \t]*$" prompt))
       (match-string 1 prompt)))

(defun claude-tasks--notification (entry)
  "The task notification text of the transcript ENTRY, or nil.
One arrives as a user entry between turns, or as a queued command during one."
  (let* ((content (alist-get 'content (alist-get 'message entry)))
         (text (cond
                ((equal (alist-get 'kind (alist-get 'origin entry)) "task-notification")
                 (if (stringp content)
                     content
                   (mapconcat (lambda (block) (or (alist-get 'text block) "")) content "")))
                ((equal (alist-get 'type (alist-get 'attachment entry)) "queued_command")
                 (alist-get 'prompt (alist-get 'attachment entry))))))
    (and (stringp text) (string-search "<task-notification>" text) text)))

(defun claude-tasks--background-entry (entry tasks calls)
  "Record what the transcript ENTRY says about background work in TASKS and CALLS."
  (let* ((message (alist-get 'message entry))
         (content (alist-get 'content message))
         (result (alist-get 'toolUseResult entry))
         (result (and (listp result) (not (stringp (car-safe result))) result))
         (time (claude-tasks--iso (alist-get 'timestamp entry))))
    (cond
     ;; A call that asks for the background: remember what it was
     ((equal (alist-get 'type entry) "assistant")
      (dolist (block (and (listp content) content))
        (when (and (equal (alist-get 'type block) "tool_use")
                   (eq (alist-get 'run_in_background (alist-get 'input block)) t))
          (let ((input (alist-get 'input block)))
            (puthash (alist-get 'id block)
                     (cons (alist-get 'description input) (alist-get 'command input))
                     calls)))))
     ;; The end of a task
     ((claude-tasks--notification entry)
      (let* ((text (claude-tasks--notification entry))
             (id (claude-tasks--xml text "task-id"))
             (status (claude-tasks--xml text "status")))
        (when-let* ((task (and id (gethash id tasks))))
          (puthash id (plist-put (plist-put task :status
                                            (pcase status
                                              ("completed" 'done) ("failed" 'failed)
                                              ("killed" 'stopped) (_ 'done)))
                                 :ended time)
                   tasks))))
     ;; A shell command left in the background
     ((stringp (alist-get 'backgroundTaskId result))
      (let* ((id (alist-get 'backgroundTaskId result))
             (call (gethash (alist-get 'tool_use_id (car-safe content)) calls)))
        (puthash id (list :kind 'shell :id id :status 'running :started time
                          :desc (or (car call) (cdr call) (format "shell %s" id))
                          :command (cdr call))
                 tasks)))
     ;; An agent started in the background
     ((equal (alist-get 'status result) "async_launched")
      (when-let* ((id (alist-get 'agentId result)))
        (puthash id (list :kind 'agent :id id :status 'running :started time
                          :desc (or (alist-get 'description result) (format "agent %s" id))
                          :task (claude-tasks--task-id (alist-get 'prompt result))
                          :model (alist-get 'resolvedModel result))
                 tasks))))))

(defun claude-tasks--tail (file from regexp function)
  "Call FUNCTION with each JSON entry of FILE after byte FROM whose line matches
REGEXP.
Only whole lines are read: the last one may still be written.  Return the
offset after the last whole line."
  (let ((size (or (file-attribute-size (file-attributes file)) 0)))
    (if (<= size from)
        from
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file nil from size)
        (goto-char (point-max))
        (let ((end (if (search-backward "\n" nil t) (1+ (point)) (point-min))))
          (goto-char (point-min))
          (while (re-search-forward regexp end t)
            (let ((line (decode-coding-string
                         (buffer-substring (line-beginning-position) (line-end-position)) 'utf-8)))
              (when-let* ((entry (ignore-errors
                                   (json-parse-string line :object-type 'alist :array-type 'list))))
                (save-excursion (funcall function entry))))
            (forward-line 1))
          (+ from (1- end)))))))

(defun claude-tasks--background-read (file)
  "Bring the state of FILE in `claude-tasks--background' up to date; return it."
  (let* ((fresh (lambda () (puthash file (list 0 (make-hash-table :test #'equal)
                                               (make-hash-table :test #'equal))
                                    claude-tasks--background)))
         (state (or (gethash file claude-tasks--background) (funcall fresh))))
    ;; A file that shrank is another file: start over
    (when (< (or (file-attribute-size (file-attributes file)) 0) (car state))
      (setq state (funcall fresh)))
    (setcar state (claude-tasks--tail
                   file (car state) claude-tasks--background-regexp
                   (lambda (entry)
                     (claude-tasks--background-entry entry (nth 1 state) (nth 2 state)))))
    state))

(defun claude-tasks--session-start (session)
  "Epoch seconds at which the newest process of SESSION started, or nil."
  (let (latest)
    (dolist (file (and (file-directory-p claude-tasks-sessions-dir)
                       (directory-files claude-tasks-sessions-dir t "\\`[0-9]+\\.json\\'")))
      (when-let* ((info (claude-agent--json-file file))
                  ((equal (alist-get 'sessionId info) session))
                  (started (alist-get 'startedAt info))
                  ((numberp started)))
        (setq latest (max (or latest 0) (/ started 1000.0)))))
    latest))

(defun claude-tasks--background (file)
  "The background tasks of the session transcript FILE, oldest first: plists of
:kind (`shell' or `agent'), :id, :desc, :command, :task (an agent's `task:' id),
:started, :ended, :session and :status (`running', `done', `failed' or
`stopped').  A task without an end that started before the session's current
process is `stopped': a restart ends shell jobs without saying so.  That is an
inference, not a record."
  (when (and file (file-readable-p file))
    (let ((hit (gethash file claude-tasks--background-recent)))
      (if (and hit (< (abs (- (float-time) (car hit))) 2))
          (cdr hit)
        (cdr (puthash file (cons (float-time) (claude-tasks--background-now file))
                      claude-tasks--background-recent))))))

(defvar claude-tasks--background-recent (make-hash-table :test #'equal)
  "Transcript FILE -> (TIME . TASKS): the answer of the last two seconds, since
a board redraw asks once per row.")

(defun claude-tasks--background-now (file)
  "The background tasks of FILE, read now."
  (progn
    (let* ((session (file-name-base file))
           (boot (claude-tasks--session-start session))
           (tasks nil))
      (maphash (lambda (_id task)
                 (let ((task (copy-sequence task)))
                   (when (and (eq (plist-get task :status) 'running) boot
                              (< (or (plist-get task :started) 0) boot))
                     (setq task (plist-put task :status 'stopped)))
                   (push (plist-put task :session session) tasks)))
               (nth 1 (claude-tasks--background-read file)))
      (sort tasks (lambda (a b) (< (or (plist-get a :started) 0) (or (plist-get b :started) 0)))))))

;;; Background tasks of headless sessions
;; A headless session's broker (container/session-broker) keeps tasks.json: the list Claude Code
;; itself gives of the session's background tasks, those of its subagents included, which no
;; transcript says.  Agents in it are left out here: they are found as subagents already.

(defvar claude-tasks-headless-globs '("~/claude/.services/*/stream/tasks.json"
                                      "~/claude/.services/x1/tasks.json")
  "Where the brokers of headless sessions keep their task lists.")

(defun claude-tasks--headless ()
  "The running background shells and monitors of the headless sessions, as tasks."
  (seq-mapcat
   (lambda (file)
     (let ((listed (claude-agent--json-file file)))
       (seq-keep
        (lambda (task)
          (let-alist task
            (unless (equal .task_type "local_agent")
              (list :kind 'shell :id .task_id :running t :status 'running
                    :type (if .parent_task_id "shell (subagent)" "shell")
                    :desc (or .description (format "shell %s" .task_id))
                    :started .started :active .started
                    :session (alist-get 'session listed)
                    :stream (file-name-directory file)))))
        (append (alist-get 'tasks listed) nil))))
   (seq-mapcat #'claude-agent-glob claude-tasks-headless-globs)))

;;; Activity of a transcript
;; What a session did last, one event per thing it did: a thought, a piece of
;; text, a tool call, an error.  `claude-tasks-activity-classify' turns one
;; transcript entry into events; `claude-tasks-activity' keeps the newest of a
;; file, reading only the bytes added since its last call.

(defvar claude-tasks-activity-tools
  '(("Read" . read) ("Grep" . read) ("Glob" . read) ("LS" . read)
    ("WebFetch" . read) ("WebSearch" . read) ("ToolSearch" . read)
    ("Edit" . edit) ("Write" . edit) ("NotebookEdit" . edit) ("MultiEdit" . edit)
    ("Bash" . bash)
    ("Agent" . agent) ("Task" . agent) ("SendMessage" . agent)
    ("AskUserQuestion" . wait))
  "Tool name to the kind of its activity event; a tool not listed runs something:
`bash'.")

(defvar claude-tasks-activity-keep 32 "Events kept per transcript.")

(defvar claude-tasks-activity-first-read 262144
  "Bytes read from the end of a transcript seen for the first time.")

(defun claude-tasks-activity-kind (tool)
  "The kind of an event for a call of TOOL."
  (alist-get tool claude-tasks-activity-tools 'bash nil #'equal))

(defun claude-tasks--activity-short (text)
  "TEXT on one line, cut to 40 characters; nil when it is not a string or blank."
  (when (and (stringp text) (not (string-blank-p text)))
    (truncate-string-to-width (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " text))
                              40 nil nil "…")))

(defun claude-tasks--activity-summary (input)
  "A few words on the tool INPUT: the file's name, else what it describes or runs."
  (let ((file (alist-get 'file_path input))
        (question (alist-get 'question (car-safe (alist-get 'questions input)))))
    (claude-tasks--activity-short
     (cond ((stringp file) (file-name-nondirectory file))
           ((stringp question) question)
           (t (seq-some (lambda (key) (let ((value (alist-get key input)))
                                        (and (stringp value) (not (string-blank-p value)) value)))
                        '(description command pattern query prompt url skill)))))))

(defun claude-tasks-activity-classify (entry)
  "The activity events of the transcript ENTRY (an alist), in order.
An event is a plist of :kind (`think', `text', `read', `edit', `bash', `agent',
`wait' or `err'), :time (epoch seconds or nil) and, where known, :tool,
:summary and :id (the tool use it belongs to).  A question to the user is a
`wait' with :pending t.  A tool result is not an event of its own: one that
failed gives an `err', any other an `answer' carrying only the :id, which
says the call returned."
  (let* ((time (claude-tasks--iso (alist-get 'timestamp entry)))
         (message (alist-get 'message entry))
         (content (alist-get 'content message))
         (blocks (and (listp content) content))
         (type (alist-get 'type entry)))
    (cond
     ((or (eq (alist-get 'isApiErrorMessage entry) t)
          (and (equal type "system") (equal (alist-get 'subtype entry) "api_error")))
      (list (list :kind 'err :time time :tool "API"
                  :summary (claude-tasks--activity-short
                            (or (alist-get 'text (car-safe blocks))
                                (and (stringp (alist-get 'content entry)) (alist-get 'content entry))
                                "API error")))))
     ((equal type "assistant")
      (seq-keep
       (lambda (block)
         (pcase (alist-get 'type block)
           ("thinking" (list :kind 'think :time time))
           ("text" (when-let* ((text (claude-tasks--activity-short (alist-get 'text block))))
                     (list :kind 'text :time time :summary text)))
           ("tool_use"
            (let* ((tool (alist-get 'name block))
                   (kind (claude-tasks-activity-kind tool)))
              (append (list :kind kind :time time :tool tool :id (alist-get 'id block)
                            :summary (claude-tasks--activity-summary (alist-get 'input block)))
                      (and (eq kind 'wait) (list :pending t)))))))
       blocks))
     ((equal type "user")
      (seq-keep
       (lambda (block)
         (when (equal (alist-get 'type block) "tool_result")
           (if (eq (alist-get 'is_error block) t)
               (list :kind 'err :time time :id (alist-get 'tool_use_id block))
             (list :kind 'answer :id (alist-get 'tool_use_id block)))))
       blocks)))))

(defvar claude-tasks--activity (make-hash-table :test #'equal)
  "Transcript FILE -> (OFFSET EVENTS CALLS): the bytes read so far, the newest
events newest first, and a hash table of tool use id to the event of a call
that has not returned.")

(defun claude-tasks--activity-add (state event)
  "Put EVENT, as `claude-tasks-activity-classify' gives it, into STATE."
  (let* ((calls (nth 2 state))
         (id (plist-get event :id))
         (call (and id (gethash id calls))))
    (pcase (plist-get event :kind)
      ((or 'answer 'err)
       ;; The call returned: a question is answered, an error names its tool
       (when call
         (plist-put call :pending nil)
         (remhash id calls))
       (when (eq (plist-get event :kind) 'err)
         (push (append event (and call (list :tool (plist-get call :tool)
                                             :summary (plist-get call :summary))))
               (nth 1 state))))
      (_ (when id (puthash id event calls))
         (push event (nth 1 state))))
    (when (> (length (nth 1 state)) claude-tasks-activity-keep)
      (setf (nth 1 state) (seq-take (nth 1 state) claude-tasks-activity-keep)))))

(defun claude-tasks--activity-read (file)
  "Bring the state of FILE in `claude-tasks--activity' up to date; return it."
  (let* ((size (or (file-attribute-size (file-attributes file)) 0))
         (fresh (lambda () (puthash file (list nil nil (make-hash-table :test #'equal))
                                    claude-tasks--activity)))
         (state (or (gethash file claude-tasks--activity) (funcall fresh))))
    ;; A file that shrank is another file: start over
    (when (and (car state) (< size (car state)))
      (setq state (funcall fresh)))
    (let* ((first (null (car state)))
           (from (or (car state) (max 0 (- size claude-tasks-activity-first-read)))))
      (when first (setcar state from))
      (when (> size from)
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert-file-contents-literally file nil from size)
          (goto-char (point-max))
          ;; Only whole lines: the last one may still be written
          (let ((end (if (search-backward "\n" nil t) (1+ (point)) (point-min))))
            (setcar state (+ from (1- end)))
            (goto-char (point-min))
            ;; A first read that starts inside the file starts inside a line
            (when (and first (> from 0)) (forward-line 1))
            (while (< (point) end)
              (when-let* ((entry (ignore-errors
                                   (json-parse-string
                                    (decode-coding-string
                                     (buffer-substring (point) (line-end-position)) 'utf-8)
                                    :object-type 'alist :array-type 'list))))
                (dolist (event (claude-tasks-activity-classify entry))
                  (claude-tasks--activity-add state event)))
              (forward-line 1))))))
    state))

(defun claude-tasks-activity (file)
  "The newest activity events of the transcript FILE, oldest first; nil without
one.
At most `claude-tasks-activity-keep' of them.  Only what was added to FILE
since the last call is read."
  (when (and file (file-readable-p file))
    (reverse (nth 1 (claude-tasks--activity-read file)))))

(defun claude-tasks--age (seconds)
  "Return SECONDS as a short age such as 4m or 2h05m."
  (let ((minutes (floor (/ seconds 60))))
    (if (< minutes 60)
        (format "%dm" minutes)
      (format "%dh%02dm" (/ minutes 60) (% minutes 60)))))

(defun claude-tasks--today-p (task)
  "Return non-nil when TASK was last active today."
  (let ((midnight (float-time (apply #'encode-time
                                     (append '(0 0 0) (nthcdr 3 (decode-time)))))))
    (>= (or (plist-get task :active) 0) midnight)))

(defun claude-tasks--stop (task)
  "Stop TASK: a headless one by a `stop_task' control request on its stream, else
ask the manager."
  (if-let* ((dir (plist-get task :stream)))
      (progn
        (claude-agent-stream-send dir `((type . "control_request")
                                        (request . ((subtype . "stop_task")
                                                    (task_id . ,(plist-get task :id))))))
        (message "Stopped %s" (plist-get task :id)))
    (claude-tasks--ask-stop task)))

(defun claude-tasks--ask-stop (task)
  "Ask the manager, on the bus (else the scheduler events), to stop TASK."
  (require 'claude-bus)
  (claude-bus-tell 'manager "tasks-stop"
                   (format "tasks-stop: %s %s" (plist-get task :id) (plist-get task :desc))
                   claude-tasks-events)
  (message "Asked %s to stop %s" claude-agent-name (plist-get task :id)))

(provide 'claude-tasks)
;;; claude-tasks.el ends here
