;;; claude-board.el --- A live table of running agents and jobs -*- coding: utf-8; lexical-binding: t -*-

;; `claude-board' is a `vtable' over the same readers as `claude-tasks' (subagent
;; meta files, jobs, watch runs, the claude-worker ledger), so there is no second
;; feed.  A file watcher on those directories redraws it through a throttle.
;; RET opens the transcript tail, k writes a stop request (the manager acts on it;
;; nothing is killed from here).

(require 'homun-dir)
(require 'homun-clock)
(require 'claude)
(require 'claude-tasks)
(require 'homun-menu)
(require 'claude-workflow)
(require 'claude-links)
(require 'filenotify)
(require 'pulse)
(require 'timeout)
(require 'cl-lib)
(require 'json)

;; Special (dynamic) before any `let' below binds them: compiled, a lexical binding would
;; stop the resize guard and the transcript lookup from seeing them.
(defvar claude-board--drawing nil "Non-nil while a board draws: no redraw starts another.")
(defvar claude-transcript--file)
(defvar-local claude-board--timer nil "When the clock last redrew this board, or nil before it watches.")
(defvar claude-board-main-dir)
(defvar claude-board-visible-columns)
(require 'vtable)
(require 'claude-agent)
(require 'claude-update)
(require 'homun-layout)

(let ((dir (expand-file-name "widgetry" homun-cockpit-dir)))
  (when (file-directory-p dir) (add-to-list 'load-path dir t)))
(require 'widgetry-meter)
(require 'widgetry-button)
(require 'widgetry-buttons)
(require 'widgetry-chips)
(require 'widgetry-activity)

(defvar claude-board-throttle 3
  "Seconds between redraws, however many files change.")

(defvar claude-board-interval 5
  "Seconds between redraws of a visible board.
Agent transcripts and ages change without touching the watched directories.")

(defvar-local claude-board--watches nil)
(defvar claude-board-mode-map)
(declare-function claude-task-detail-open "claude-task-detail")

(defvar claude-board-quiet-after 600
  "Seconds without a write after which a subagent is taken as gone.")

(defun claude-board--live-p (task)
  "Whether TASK is running and, for a subagent, still being written to."
  (and (plist-get task :running)
       (or (not (eq (plist-get task :kind) 'subagent))
           (< (- (float-time) (or (plist-get task :active) 0)) claude-board-quiet-after))))

(defvar-local claude-board--finished nil
  "Non-nil when the board also lists the subagents that finished today.")

(defun claude-board--shown-p (task)
  "Whether TASK is live, or a subagent finished today while
`claude-board--finished'."
  (or (claude-board--live-p task)
      (and claude-board--finished
           (eq (plist-get task :kind) 'subagent)
           (claude-tasks--today-p task))
      (and (eq (plist-get task :kind) 'workflow) (claude-tasks--today-p task))))

(defun claude-board--shells ()
  "The shell commands the Manager's session left running in the background, as
tasks."
  (when-let* ((main (ignore-errors (claude-board--role-file 'manager claude-board-main-dir))))
    (seq-keep (lambda (task)
                (when (and (eq (plist-get task :kind) 'shell)
                           (eq (plist-get task :status) 'running))
                  (append (list :running t :type "shell" :active (plist-get task :started))
                          task)))
              (ignore-errors (claude-tasks--background main)))))

(defun claude-board--before-p (a b)
  "Whether task A starts before B; a tie goes by transcript then description.
Nothing here depends on activity or state, so rows keep their place and a new
one appends at the end of its group."
  (let ((sa (or (plist-get a :started) most-positive-fixnum))
        (sb (or (plist-get b :started) most-positive-fixnum)))
    (if (= sa sb)
        (string< (format "%s%s" (or (plist-get a :transcript) "") (or (plist-get a :desc) ""))
                 (format "%s%s" (or (plist-get b :transcript) "") (or (plist-get b :desc) "")))
      (< sa sb))))

(defun claude-board--tasks ()
  "The running tasks in a stable order: the oldest first."
  (let ((tasks (seq-filter #'claude-board--shown-p
                           (append (claude-tasks--subagents) (claude-tasks--jobs)
                                   (claude-tasks--watches) (claude-tasks--workers)
                                   (claude-board--shells) (claude-tasks--headless)
                                   (claude-workflow-runs)))))
    (sort tasks #'claude-board--before-p)))

;;; Context and plan usage

(defvar claude-board-window-small 200000 "Context window of a model without the 1M variant.")
(defvar claude-board-window-large 1000000 "Context window of the 1M variant.")

(defun claude-board-context-tokens (usage)
  "Tokens in context according to USAGE, a message.usage hash table: input
plus cache read plus cache creation tokens; nil when USAGE has none of them."
  (let ((keys '("input_tokens" "cache_read_input_tokens" "cache_creation_input_tokens")))
    (when (seq-some (lambda (k) (numberp (gethash k usage))) keys)
      (apply #'+ (mapcar (lambda (k) (let ((v (gethash k usage))) (if (numberp v) v 0))) keys)))))

(defun claude-board-window (model tokens)
  "Context window for MODEL (an id or nil) holding TOKENS: the 1M window when
the id says 1m (\"[1m]\", \"-1m\") or TOKENS exceed the 200k one, else 200k."
  (if (or (and (stringp model) (string-match-p "[-[]1m\\b" model))
          (> tokens claude-board-window-small))
      claude-board-window-large
    claude-board-window-small))

(defvar claude-board--window-cache (make-hash-table :test #'equal)
  "(session . ID) or (model . ID) -> (TIME . WINDOW or nil), kept for 60 s.")

(defun claude-board--window-query (key sql value)
  "The context window SQL gives for VALUE, cached under KEY for 60 s; nil if none."
  (let ((hit (gethash key claude-board--window-cache)))
    (if (and hit (< (- (float-time) (car hit)) 60))
        (cdr hit)
      (let ((window (ignore-errors (caar (claude-agent--select sql value)))))
        (puthash key (cons (float-time) (and (integerp window) (> window 0) window))
                 claude-board--window-cache)
        (cdr (gethash key claude-board--window-cache))))))

(defun claude-board--window-size (session model tokens)
  "Context window of SESSION (an id or nil) running MODEL with TOKENS in context.
The window Claude Code last reported for the session; without one (a subagent),
the one it last reported for the model, which is an estimate; else the guess of
`claude-board-window'."
  (or (and session
           (claude-board--window-query
            (cons 'session session)
            "select context_window_size from samples where session_id = ?1
             and context_window_size is not null order by ts desc limit 1"
            session))
      (and (stringp model)
           (claude-board--window-query
            (cons 'model model)
            "select context_window_size from samples where model = ?1
             and context_window_size is not null order by ts desc limit 1"
            model))
      (claude-board-window model tokens)))

(defun claude-board--fmt-window (window)
  "WINDOW tokens as a short label: \"1M\", \"200k\"."
  (if (and (>= window 1000000) (zerop (% window 1000000)))
      (format "%dM" (/ window 1000000))
    (format "%dk" (/ window 1000))))

(defvar claude-board--context-cache (make-hash-table :test #'equal)
  "Transcript file -> ((SIZE . MTIME) . (TOKENS MODEL)) or nil.")

(defun claude-board--context-read (file)
  "(TOKENS MODEL) from the last assistant usage in the last 64 KB of FILE, or nil."
  (with-temp-buffer
    (insert-file-contents file nil (max 0 (- (file-attribute-size (file-attributes file)) 65536)))
    (goto-char (point-max))
    (let (found)
      (while (and (not found) (zerop (forward-line -1)))
        (when (looking-at-p ".*\"usage\"")
          (setq found (ignore-errors
                        (let* ((message (gethash "message" (json-parse-string
                                                            (buffer-substring (point) (line-end-position)))))
                               (tokens (claude-board-context-tokens (gethash "usage" message))))
                          (and tokens (list tokens (let ((model (gethash "model" message)))
                                                     (and (stringp model) model)))))))))
      found)))

(defun claude-board--context (file)
  "(TOKENS WINDOW) of the transcript FILE, cached per size and mtime; nil if
unknown."
  (when-let* ((attrs (and file (file-attributes file)))
              (stamp (cons (file-attribute-size attrs) (file-attribute-modification-time attrs))))
    (let ((hit (gethash file claude-board--context-cache)))
      (if (and hit (equal (car hit) stamp))
          (claude-board--context-window file (cdr hit))
        (let ((value (ignore-errors (claude-board--context-read file))))
          (puthash file (cons stamp value) claude-board--context-cache)
          (claude-board--context-window file value))))))

(defun claude-board--context-window (file read)
  "(TOKENS WINDOW) for READ, the (TOKENS MODEL) of the transcript FILE, or nil.
A top-level transcript is named after its session; a subagent's has none."
  (when read
    (list (car read)
          (claude-board--window-size
           (and (not (string-search "/subagents/" file)) (file-name-base file))
           (cadr read) (car read)))))

(defun claude-board--context-cell (task)
  "A small bar and percent of the context of TASK, coloured by level; \"\" if
unknown."
  (if-let* ((ctx (claude-board--context (plist-get task :transcript)))
            (fraction (min 1.0 (/ (float (car ctx)) (cadr ctx)))))
      (concat (widgetry-meter-string fraction 5) (format " %3d%%" (round (* fraction 100))))
    ""))

(defvar claude-board--usage-cache nil "(TIME . ROW) of the latest plan usage sample.")

(defun claude-board--usage ()
  "(FIVE-USED FIVE-RESET SEVEN-USED SEVEN-RESET) of the newest sample (percent,
epoch), or nil.
One indexed row, cached for 30 seconds."
  (if (and claude-board--usage-cache (< (- (float-time) (car claude-board--usage-cache)) 30))
      (cdr claude-board--usage-cache)
    (let ((row (ignore-errors
                 (car (claude-agent--select
                       "select five_hour_used, five_hour_resets_at, seven_day_used, seven_day_resets_at
                        from samples where five_hour_used is not null order by ts desc limit 1")))))
      (setq claude-board--usage-cache (cons (float-time) row))
      row)))

(defvar claude-board-controls-inline 110
  "Window width in characters from which the controls share the Context line;
narrower, they get their own line above the meters, so nothing wraps.")

(defvar claude-board-stack-below 50
  "Window width in characters below which a meter's label is stacked above its bar.")

(defun claude-board-meter-width (chars text-length)
  "Bar width for a window CHARS wide with TEXT-LENGTH characters of text after it.
Between 6 and 24; in a window under `claude-board-stack-below' the label sits
above the bar, so only the margins are taken off."
  (max 6 (min 24 (if (< chars claude-board-stack-below)
                     (- chars 4)
                   (- chars 11 1 text-length 1)))))

(defun claude-board--meter (label fraction text &optional after)
  "Insert a read-only meter: LABEL, a bar for FRACTION, then TEXT.
Wide: one line, then AFTER (a function inserting at the end of it).
Narrow: LABEL and TEXT on a line, the bar under it, AFTER not called."
  (let* ((chars (claude-board--chars))
         (stacked (< chars claude-board-stack-below))
         (width (claude-board-meter-width chars (length text))))
    (if stacked
        (insert (propertize (format "  %s" label) 'face 'shadow) " " text "\n  ")
      (insert (propertize (format "  %-9s" label) 'face 'shadow)))
    (widget-create 'widgetry-meter :read-only t :width width :tag "" :value fraction
                   :fill-face (widgetry-meter-level-face fraction))
    (insert (if stacked "" (concat " " text)))
    (when (and after (not stacked)) (funcall after))
    (insert "\n")))

(defun claude-board--until (epoch)
  "\"resets in 2h 5m\" for EPOCH."
  (let ((left (- epoch (float-time))))
    (if (<= left 0) "window rolled over" (concat "resets in " (claude-tasks--age left)))))

(defun claude-board--compacting-p ()
  "Non-nil while the manager compacts, by the transcript's compaction reader."
  (and (fboundp 'claude-transcript--compact-status)
       (when-let* ((text (claude-transcript--compact-status)))
         (string-match-p "Compacting" text))))

(defun claude-board--homun-state (main)
  "What the manager does, as text and a face: \"Bash 12s\", \"idle\" or \"compacting…\"."
  (if (claude-board--compacting-p)
      (cons "compacting…" 'warning)
    (let ((state (and (fboundp 'claude-transcript--busy-state)
                      (let ((claude-transcript--file (plist-get main :transcript)))
                        (ignore-errors (claude-transcript--busy-state))))))
      (if state
          (let* ((tool (alist-get 'tool state))
                 (label (claude-transcript--busy-label state)))
            (cons (format "%s %ds"
                          (if (and tool (not (string-empty-p tool))) tool "thinking")
                          (cdr label))
                  'warning))
        (cons "idle" 'shadow)))))

(defun claude-board--controls ()
  "Insert the Recreate, Compact and Settings group and the Finished chip at the
right edge of the line."
  (let ((spacer (point))
        (pending (claude-update-pending-label)))
    (insert " ")
    (when pending (insert pending "  "))
    (let* ((group (widget-create
                   'widgetry-buttons
                   :buttons (append (claude-update-buttons)
                                  (list (list :label "Compact"
                                        :disabled (and (claude-board--compacting-p) t)
                                        :shown (lambda (widget)
                                                 (if-let* (((claude-board--compacting-p))
                                                           (text (claude-transcript--compact-status)))
                                                     (format " %s %s "
                                                             (aref claude-update--spinner
                                                                   (% claude-update--spin-frame 10))
                                                             (string-trim text))
                                                   (widget-value widget)))
                                        :notify (lambda (&rest _)
                                                  (unless (claude-board--compacting-p)
                                                    (claude-compact t))))
                                  (list :label "Settings"
                                        :notify (lambda (&rest _) (claude-settings)))))))
           (_ (claude-update-help-echo group))
           (_ (setq claude-update--group group))
           (_ (claude-update--spin-start))
           (_ (insert " "))
           (chip (widget-create
                  'widgetry-chips :choices '(Finished)
                  :value (and claude-board--finished '(Finished))
                  :notify (let ((board (current-buffer)))
                            (lambda (&rest _)
                              ;; The timer runs in whatever buffer is current then,
                              ;; so go back to the board before toggling and drawing
                              (run-at-time 0 nil (lambda ()
                                                   (when (buffer-live-p board)
                                                     (with-current-buffer board
                                                       (claude-board-toggle-finished))))))))))
      (put-text-property
       spacer (1+ spacer) 'display
       ;; A terminal keeps its last column for the wrap mark: stay clear of it
       `(space :align-to (- right-fringe ,(+ (widgetry-buttons-width group) 1
                                             (string-width (widgetry-shown chip)) 2
                                             (if pending (+ 2 (string-width pending)) 0)
                                             (if (display-graphic-p) 0 1))))))))

(defun claude-board--meters (main)
  "Insert the meter block: context of MAIN with the controls at the end of its
line, then the 5-hour and 7-day plan usage, then what the manager is doing."
  (setq widget-field-list nil widget-field-new nil)
  (let ((narrow (< (claude-board--chars) claude-board-controls-inline)))
    (when narrow (claude-board--controls) (insert "\n"))
    (if-let* ((ctx (claude-board--context (plist-get main :transcript))))
        (claude-board--meter "Context" (min 1.0 (/ (float (car ctx)) (cadr ctx)))
                             (format "%dk of %s tokens" (/ (car ctx) 1000)
                                     (claude-board--fmt-window (cadr ctx)))
                             (unless narrow #'claude-board--controls))
      (insert (propertize "  Context   unknown" 'face 'shadow))
      (unless narrow (claude-board--controls))
      (insert "\n")))
  (if-let* ((usage (claude-board--usage)))
      (cl-destructuring-bind (five five-at seven seven-at) usage
        (claude-board--meter "5 hours" (/ (or five 0) 100.0)
                             (if five-at (claude-board--until five-at) ""))
        (claude-board--meter "7 days" (/ (or seven 0) 100.0)
                             (if seven-at (claude-board--until seven-at) "")))
    (insert (propertize "  Plan usage unknown\n" 'face 'shadow)))
  (when (require 'claude-transcript nil t)
    (let ((state (claude-board--homun-state main)))
      (insert (propertize (format "  %-9s" claude-agent-name) 'face 'shadow)
              (propertize (car state) 'face (cdr state)) "\n")))
  (widget-setup))

;; The main session's transcript is the newest top-level jsonl; subagent ones live in
;; <session>/subagents/, so it is never listed twice.
(defun claude-board--project-dir ()
  "The Manager\='s transcript directory: Claude Code names it after ~/claude with /
as -."
  (expand-file-name
   (concat "~/.claude/projects/"
           (replace-regexp-in-string "/" "-" (expand-file-name "~/claude"))
           "/")))

(defvar claude-board-main-dir (claude-board--project-dir)
  "Directory holding the transcript of the main session.")

(defvar claude-board-role-dirs
  `((manager . ,(claude-board--project-dir))
    (mechanic . "/mnt/mechanic-claude/projects/"))
  "Each role's transcripts: a project directory, or a projects directory whose
subdirectories are searched.  Roles whose directory is missing are skipped.")

(defun claude-board--role-file (role dir)
  "The current session transcript of ROLE under DIR, or nil.
The Manager's pinned session (~/.claude/manager-session) when it exists, else
the newest top-level transcript."
  (let* ((dir (expand-file-name dir))
         (id (if (eq role 'manager)
                 (claude-main-session-id)
               (ignore-errors
                 (string-trim (with-temp-buffer
                                (insert-file-contents (expand-file-name (format "~/.claude/%s-session" role)))
                                (buffer-string))))))
         (pinned (and id (expand-file-name (concat id ".jsonl") dir))))
    (cond
     ((and pinned (file-readable-p pinned)) pinned)
     ;; A remote cockpit has no local transcripts
     ((file-directory-p dir)
      ;; Listings are reused while each directory's mtime holds; every transcript is
      ;; stat once, since appending to one changes no directory
      (claude-agent-newest (append (claude-agent-glob (concat (file-name-as-directory dir) "*.jsonl"))
                                   (claude-agent-glob (concat (file-name-as-directory dir) "*/*.jsonl"))))))))

(defun claude-board--mains ()
  "A main row for each role whose transcripts are visible here."
  (delq nil
        (mapcar (lambda (entry)
                  (pcase-let ((`(,role . ,dir) entry))
                    (when-let* (((file-directory-p (expand-file-name dir)))
                                (file (claude-board--role-file role dir)))
                      (let ((speaker (and (fboundp 'claude-homun-role-style)
                                          (claude-homun-role-style (symbol-name role)))))
                        (list :kind 'main :role role
                              :desc (string-trim (concat (plist-get speaker :emoji) " "
                                                         (or (plist-get speaker :name)
                                                             (symbol-name role))))
                              :running t :transcript file
                              :model (claude-board--main-model file)
                              :started (claude-board--main-start file))))))
                claude-board-role-dirs)))

(declare-function claude-handoff-list "claude-handoff")
(declare-function claude-handoff-open "claude-handoff")
(declare-function claude-handoff-stop "claude-handoff")

(defun claude-board--handoffs ()
  "A row for each running handoff session (bin/claude-handoff)."
  (require 'claude-handoff)
  (mapcar (lambda (meta)
            (list :kind 'handoff :handoff (plist-get meta :name)
                  :desc (concat "≡ " (plist-get meta :name)) :running t
                  :transcript (plist-get meta :jsonl)
                  :started (ignore-errors (float-time (date-to-time (plist-get meta :started))))))
          (seq-filter (lambda (meta) (plist-get meta :running)) (claude-handoff-list))))

(defun claude-board--main (&optional tasks)
  "The main row of the Manager among TASKS (default: the main rows, read again), or
nil."
  (seq-find (lambda (task) (eq (plist-get task :role) 'manager))
            (or tasks (claude-board--mains))))

(defun claude-board--main-start (file)
  "Epoch seconds of the first timestamp in the head of FILE, or nil."
  (with-temp-buffer
    (insert-file-contents file nil 0 200000)
    (when (re-search-forward "\"timestamp\":\"\\([^\"]+\\)\"" nil t)
      (ignore-errors (float-time (date-to-time (match-string 1)))))))

(defun claude-board--main-model (file)
  "The model named in the tail of FILE, or nil."
  (with-temp-buffer
    (insert-file-contents file nil (max 0 (- (file-attribute-size (file-attributes file)) 65536)))
    (goto-char (point-max))
    (when (re-search-backward "\"model\":\"\\([^\"]+\\)\"" nil t)
      (match-string 1))))

(defun claude-board--summary (entry)
  "One line for ENTRY: its assistant text, or \"tool: NAME detail\"; nil when empty."
  (when (equal (gethash "type" entry) "assistant")
    (let* ((content (gethash "content" (or (gethash "message" entry) #s(hash-table))))
           (blocks (if (vectorp content) (append content nil)))
           (text (seq-some (lambda (b) (and (equal (gethash "type" b) "text")
                                            (gethash "text" b)))
                           blocks))
           (tool (seq-find (lambda (b) (equal (gethash "type" b) "tool_use")) blocks)))
      (cond ((and text (not (string-blank-p text))) (string-trim text))
            (tool (let* ((input (or (gethash "input" tool) #s(hash-table)))
                         (detail (seq-some (lambda (k) (let ((v (gethash k input))) (and (stringp v) v)))
                                           '("description" "command" "file_path" "path" "pattern" "query"))))
                    (format "tool: %s %s" (gethash "name" tool) (or detail ""))))))))

(defvar claude-board--last-line-cache (make-hash-table :test #'equal)
  "File to ((SIZE . MTIME) . LINE): the last line is read again only when the file
changed.")

(defun claude-board--last-line (task)
  "The newest meaningful entry of the transcript of TASK as plain text on one line."
  (let* ((file (plist-get task :transcript))
         (attrs (and file (file-attributes file)))
         (stamp (and attrs (cons (file-attribute-size attrs) (file-attribute-modification-time attrs))))
         (hit (and stamp (gethash file claude-board--last-line-cache))))
    (if (and hit (equal (car hit) stamp))
        (cdr hit)
      (let ((line (claude-board--last-line-read task)))
        (when stamp (puthash file (cons stamp line) claude-board--last-line-cache))
        line))))

(defun claude-board--last-line-read (task)
  "The newest meaningful entry of the transcript of TASK, read from the file."
  (or (when-let* ((file (plist-get task :transcript))
                  ((file-readable-p file)))
        (with-temp-buffer
          (insert-file-contents file nil (max 0 (- (file-attribute-size (file-attributes file)) 65536)))
          (goto-char (point-max))
          (let (found)
            (while (and (not found) (zerop (forward-line -1)) (not (bobp)))
              (setq found (ignore-errors
                            (claude-board--summary
                             (json-parse-string (buffer-substring (line-beginning-position)
                                                                  (line-end-position)))))))
            (and found (replace-regexp-in-string "[ \t\n]+" " " found)))))
      ""))

(defun claude-board--age (task)
  "Age of TASK as `claude-tasks--age' shows it."
  (if-let* ((started (plist-get task :started)))
      (claude-tasks--age (- (float-time) (if (numberp started) started (float-time started))))
    ""))

(defvar claude-board--rows nil "While drawing: task to its row, so each row is built once.")

(defun claude-board--row (task)
  "The vtable row (list of cells) of TASK, built once per draw."
  (if claude-board--rows
      (or (gethash task claude-board--rows)
          (puthash task (claude-board--row-build task) claude-board--rows))
    (claude-board--row-build task)))

(defun claude-board--background-status (task)
  "The status a task notification in the Manager's transcript gave the agent TASK,
or nil.
A status only inferred from a restart is left out: the agent's own meta file
knows better."
  (when-let* (((eq (plist-get task :kind) 'subagent))
              (id (plist-get task :id))
              (main (ignore-errors (claude-board--role-file 'manager claude-board-main-dir)))
              (found (seq-find (lambda (other) (equal (plist-get other :id) id))
                               (ignore-errors (claude-tasks--background main)))))
    (and (plist-get found :ended) (plist-get found :status))))

(defun claude-board--state (task &optional status)
  "The state of TASK: `running', `done', `failed' or `stopped'.
STATUS is what a task notification said of it, when one did.  Live work is
running; a notification decides the rest; without one a subagent whose meta
file says finished is done, and one that only went quiet is stopped."
  (cond ((claude-board--live-p task) 'running)
        ((memq status '(done failed stopped)) status)
        ((plist-get task :running) 'stopped)
        (t 'done)))

(defconst claude-board--state-faces
  '((running . widgetry-status-pending) (done . widgetry-status-done)
    (failed . widgetry-status-failed) (stopped . widgetry-status-stopped))
  "The face of a row's state dot.")

(defun claude-board--emoji-slot (emoji)
  "A blank as wide as EMOJI and the space after it, or the empty string."
  (if (string-empty-p emoji)
      ""
    (propertize " " 'display
                `(space :width ,(/ (float (string-pixel-width (concat emoji " "))) (default-font-width))))))

(defun claude-board--task-cell (task)
  "The description of TASK after a dot in the colour of its state.
The dot is always first.  A child row puts a blank the width of its parent's
emoji after it, then its branch, so dots and emoji each line up in a column."
  (let* ((state (claude-board--state task (claude-board--background-status task)))
         (full (or (plist-get task :desc) ""))
         (branch (if (string-match "\\`[│ ]*[├└] " full) (match-string 0 full) ""))
         (desc (substring full (length branch)))
         (desc (if (and (eq (plist-get task :kind) 'shell)
                        (not (string-prefix-p "$ " desc)))
                   (concat "$ " desc)
                 desc)))
    (concat (propertize "●" 'face (alist-get state claude-board--state-faces)
                        'help-echo (symbol-name state))
            " "
            (and (not (string-empty-p branch))
                 (claude-board--emoji-slot (or (plist-get task :emoji) "")))
            branch desc)))

;;; Activity
;; What a row's session did last, one cell an event (`widgetry-activity-strip'),
;; from the transcript reader of claude-tasks and the permission requests that
;; wait for the user.  Nothing here has a timer: the cells change when a redraw
;; finds the transcript longer.

(defvar claude-board-activity-cells 14 "Cells of a row's activity strip.")

(defvar claude-board-activity-detail nil
  "Non-nil when a row names its latest activity next to the strip: \"● edit\".")

(defun claude-board--activity-width ()
  "Characters of the Activity column: the strip and, in detail, the latest kind."
  (+ claude-board-activity-cells
     (if claude-board-activity-detail (1+ widgetry-activity-latest-width) 0)))

(defvar claude-approve-dir)
(declare-function claude-approve--requests "claude-approve")

(defun claude-board--read-requests ()
  "The pending permission requests, or nil when approvals are not loaded."
  (and (fboundp 'claude-approve--requests) (ignore-errors (claude-approve--requests))))

(defvar claude-board--requests 'unread
  "While drawing: the pending permission requests, read once for all rows.
`unread' outside a draw, where they are read when asked for.")

(defun claude-board--permission-waits (task)
  "A pending `wait' event for each permission request TASK waits on.
A request names the subagent that asks; one that names none is the Manager's."
  (seq-keep (lambda (request)
              (let* ((agent (alist-get 'agent request))
                     (id (and (listp agent) (alist-get 'id agent))))
                (when (if id
                          (and (eq (plist-get task :kind) 'subagent) (equal id (plist-get task :id)))
                        (eq (plist-get task :role) 'manager))
                  (list :kind 'wait :pending t :tool (alist-get 'tool request)
                        :summary (let ((summary (alist-get 'summary request)))
                                   (and (stringp summary) (claude-board--clip summary 40)))
                        :time (let ((since (alist-get 'since request)))
                                (and (numberp since) since))))))
            (if (eq claude-board--requests 'unread)
                (claude-board--read-requests)
              claude-board--requests)))

(defun claude-board--activity (task)
  "The activity events of TASK, oldest first; nil for a task without a transcript."
  (when-let* ((file (plist-get task :transcript)))
    (append (ignore-errors (claude-tasks-activity file))
            (claude-board--permission-waits task))))

(defun claude-board--activity-cell (task)
  "The activity strip of TASK, in detail followed by its latest kind; \"\" for
a task without a transcript."
  (if (and (plist-get task :transcript) (not (eq (plist-get task :kind) 'workflow)))
      (let ((events (claude-board--activity task)))
        (concat (widgetry-activity-strip events claude-board-activity-cells)
                (and claude-board-activity-detail
                     (concat " " (widgetry-activity-latest events)))))
    ""))

(defun claude-board--row-build (task)
  (list (claude-board--task-cell task)
        (or (plist-get task :type) "") (format "%s" (or (plist-get task :model) ""))
        (claude-board--age task) (claude-board--context-cell task)
        (claude-board--activity-cell task)))

(defun claude-board--cell (task col)
  "Cell COL of TASK; the age is secondary, so it is shadowed."
  (let ((text (nth col (claude-board--row task))))
    (cond ((eq col 3) (propertize text 'face 'shadow))
          ((eq col 0) (claude-board--with-tooltip task text))
          (t text))))

(defun claude-board--tooltip (task)
  "The last line of TASK, wrapped to about 80 characters; nil when there is none."
  (let ((line (claude-board--last-line task))
        (fill-column 80))
    (when (and line (not (string-empty-p line)))
      (with-temp-buffer
        (insert line)
        (fill-region (point-min) (point-max))
        (buffer-string)))))

(defun claude-board--with-tooltip (task cell)
  "CELL with the tooltip of TASK after its state dot, which keeps its own."
  (let ((cell (copy-sequence cell))
        (tip (claude-board--tooltip task)))
    (when (and tip (> (length cell) 1))
      (put-text-property 1 (length cell) 'help-echo tip cell))
    cell))

;; The vtable puts its keymap on the text, above evil's states: only RET goes
;; there, so evil's motions (k, j, gg, ...) reach the buffer.
(defvar claude-board-row-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'claude-board-open)
    ;; The board keeps its own order: no sort key and no header click sorts it
    (define-key map (kbd "S") #'ignore)
    (define-key map [header-line mouse-1] #'ignore)
    (define-key map [header-line mouse-2] #'ignore)
    map))

(defun claude-board-tap (event)
  "Set point where EVENT is and open the detail of that row."
  (interactive "e")
  (mouse-set-point event)
  (claude-board-detail))

;; Outside the `defvar', so that a reload gives an existing map the tap too
(define-key claude-board-row-map [mouse-1] #'claude-board-tap)

(defun claude-board--session-of (task)
  "The id of the session TASK belongs to: its own for a main session, its
parent's for a subagent (<dir>/<session>/subagents/agent-*.jsonl), its :session
for a background shell command, else nil."
  (if-let* ((file (plist-get task :transcript)))
    (if (eq (plist-get task :kind) 'main)
        (file-name-base file)
      (when (string-match "/\\([^/]+\\)/subagents/\\(?:workflows/[^/]+/\\)?[^/]+\\'" file)
        (match-string 1 file)))
    (plist-get task :session)))

(defun claude-board--project-of (task)
  "The project directory of TASK's transcript: <dir> of <dir>/<session>.jsonl or
<dir>/<session>/subagents/[workflows/<run>/]agent-*.jsonl, else nil."
  (when-let* ((file (plist-get task :transcript)))
    (file-name-directory
     (if (string-match "/[^/]+/subagents/\\(?:workflows/[^/]+/\\)?[^/]+\\'" file)
         (substring file 0 (1+ (match-beginning 0)))
       file))))

(defconst claude-board--legend-kinds
  '((think . "think") (text . "text") (read . "read") (edit . "edit") (bash . "command")
    (agent . "agent") (wait . "waiting") (err . "error") (idle . "idle"))
  "The kinds of the Activity legend with the word each goes by.")

(defun claude-board--legend ()
  "The Activity legend: each kind's glyph in its colour and a word, dim, one line."
  (mapconcat (lambda (kind)
               (concat (propertize (widgetry-activity-glyph (car kind))
                                   'face (widgetry-activity-face (car kind)))
                       (propertize (concat " " (cdr kind)) 'face 'shadow)))
             claude-board--legend-kinds "  "))

(defun claude-board--emoji-of (main)
  "The emoji that starts the description of MAIN, or the empty string."
  (let ((word (car (split-string (or (plist-get main :desc) "")))))
    (if (and word (string-match-p "[^[:ascii:]]" word)) word "")))

(defun claude-board--nest (children)
  "CHILDREN as (TASK . KIDS): a workflow run's agents become the KIDS of its row;
an agent whose run is not listed stays a child of its own."
  (let ((runs (seq-keep (lambda (task) (and (eq (plist-get task :kind) 'workflow) (plist-get task :run)))
                        children)))
    (seq-keep (lambda (task)
                (cond ((eq (plist-get task :kind) 'workflow)
                       (cons task (seq-filter (lambda (kid) (and (not (eq (plist-get kid :kind) 'workflow))
                                                                 (equal (plist-get kid :run) (plist-get task :run))))
                                              children)))
                      ((member (plist-get task :run) runs) nil)
                      (t (list task))))
              children)))

(defun claude-board--tree (tasks)
  "TASKS ordered as a tree: each main session followed by its subagents, whose
Task cell gets a branch (├ or └).  A subagent whose session is not listed (its
parent was resumed as a new session) goes under the first main session of the
same project; tasks of no listed session or project come last."
  (let* ((mains (seq-filter (lambda (task) (eq (plist-get task :kind) 'main)) tasks))
         (rest (seq-difference tasks mains #'eq))
         (listed (mapcar #'claude-board--session-of mains))
         (ordered nil))
    (dolist (main mains)
      (let* ((session (claude-board--session-of main))
             (project (claude-board--project-of main))
             (children (seq-filter
                        (lambda (task)
                          (let ((own (claude-board--session-of task)))
                            (or (equal own session)
                                (and own (not (member own listed))
                                     (equal (claude-board--project-of task) project)))))
                        rest)))
        (setq rest (seq-difference rest children #'eq))
        (push (if children (plist-put (copy-sequence main) :kids t) main) ordered)
        (setq children (claude-board--nest children))
        (while children
          (let* ((entry (pop children))
                 (child (copy-sequence (car entry)))
                 (kids (cdr entry))
                 (emoji (claude-board--emoji-of main)))
            (setq child (plist-put child :emoji emoji))
            (setq child (plist-put child :tree (if children 'mid 'last)))
            (push (plist-put child :desc (concat (if children "├ " "└ ")
                                                 (or (plist-get child :desc) "")))
                  ordered)
            (let ((pad (if children "│ " "  ")))
              (while kids
                (let ((kid (copy-sequence (pop kids))))
                  (setq kid (plist-put kid :emoji emoji))
                  (setq kid (plist-put kid :tree (if kids 'mid 'last)))
                  (push (plist-put kid :desc (concat pad (if kids "├ " "└ ")
                                                     (or (plist-get kid :desc) "")))
                        ordered))))))))
    (append (nreverse ordered) rest)))

(defvar-local claude-board--selected nil
  "The :transcript of the row last selected; point returns to that task after a
redraw.")

(defun claude-board--remember ()
  "Remember the task at point (post-command hook): by its transcript, not its line."
  (when-let* ((task (claude-board--task-at-point))
              (file (plist-get task :transcript)))
    (setq claude-board--selected file)))

(defun claude-board--goto-selected (tasks)
  "Put point on the row of the remembered task among TASKS, else on the first row."
  (let ((task (or (seq-find (lambda (task) (equal (plist-get task :transcript) claude-board--selected))
                            (and claude-board--selected tasks))
                  (car tasks))))
    (goto-char (point-min))
    (when (and task (text-property-search-forward 'vtable-object task #'eq))
      (forward-line -1))))

(defvar claude-board-columns
  '(("Task" 0 24 nil) ("Type" 1 12 2) ("Model" 2 16 4)
    ("Age" 3 6 3) ("Context" 4 10 5) ("Activity" 5 14 6))
  "Board columns as (NAME CELL-INDEX WIDTH DROP-RANK), in display order.
WIDTH is in characters: the width of a fixed column, the minimum of Task.
A column with a DROP-RANK is dropped, lowest rank first, when the window is
too narrow, so Task keeps its width first; Task (no rank) is never dropped and
takes every character the others leave.")

(defvar claude-board-column-gap 1 "Characters between columns, as the table spaces them.")

(defconst claude-board-optional-columns '(type model age context activity)
  "The columns `claude-board-visible-columns' can hide; Task stays.")

(defvar claude-board-visible-columns claude-board-optional-columns
  "The optional columns the board shows (symbols of
`claude-board-optional-columns').
A hidden column gives its width to Task.  Set from the settings page or `c' on
the board.")

(defun claude-board--columns ()
  "`claude-board-columns' that are visible, with Activity as wide as its strip is
now."
  (delq nil
        (mapcar (lambda (col)
                  (let ((key (intern (downcase (car col)))))
                    (cond ((and (memq key claude-board-optional-columns)
                                (not (memq key claude-board-visible-columns)))
                           nil)
                          ((equal (car col) "Activity")
                           (list (car col) (cadr col) (claude-board--activity-width) (cadddr col)))
                          (t col))))
                claude-board-columns)))

(defun claude-board-layout (chars)
  "Columns shown in a window CHARS wide: a list of (NAME CELL-INDEX WIDTH).
See `claude-board-columns' for what is dropped; Task takes the spare width."
  (let ((cols (claude-board--columns)))
    (cl-flet ((need () (+ (apply #'+ (mapcar #'caddr cols))
                          (* claude-board-column-gap (1- (length cols))))))
      (while (and (> (need) chars) (seq-some #'cadddr cols))
        (setq cols (remq (car (sort (seq-filter #'cadddr cols)
                                    (lambda (a b) (< (cadddr a) (cadddr b)))))
                         cols)))
      (let ((spare (max 0 (- chars (need)))))
        (mapcar (lambda (col)
                  (list (car col) (cadr col)
                        (if (equal (car col) "Task") (+ (caddr col) spare) (caddr col))))
                cols)))))

(defun claude-board-pixel-widths (layout body char &optional natural)
  "Pixel widths of the columns of LAYOUT that fill BODY pixels to the pixel.
CHAR is the pixel width of a character.  NATURAL, when given, holds for each
column the pixel width of its widest cell, or nil: a column other than Task
whose cells hold glyphs wider than a character (a fallback font, an emoji) is
widened to it, so they are not cut.  Task takes what is left; it keeps two
characters at least."
  (let* ((fixed (seq-map-indexed
                 (lambda (col index)
                   (if (equal (car col) "Task")
                       0
                     (max (* (caddr col) char) (or (nth index natural) 0))))
                 layout))
         (gaps (* claude-board-column-gap char (1- (length layout))))
         (rest (max (* 2 char) (- body gaps (apply #'+ fixed)))))
    (seq-map-indexed (lambda (col index)
                       (if (equal (car col) "Task") rest (nth index fixed)))
                     layout)))

(defun claude-board--body-pixels ()
  "Pixels a line of the board may fill: the body of its window, less one
character in a terminal, whose last column holds the truncation mark."
  (if-let* ((window (get-buffer-window nil t)))
      (- (window-body-width window t) (if (display-graphic-p (window-frame window)) (default-font-width) 1))
    (* 120 (default-font-width))))

(defun claude-board--chars ()
  "Width in characters of the board's window; 120 when it has none."
  (if-let* ((window (get-buffer-window nil t)))
      (floor (window-body-width window t) (default-font-width))
    120))

(defvar-local claude-board--width nil "Body width in pixels of the window at the last redraw.")

(defun claude-board--clip (text width)
  "TEXT cut to WIDTH characters with an ellipsis."
  (truncate-string-to-width text width nil nil "…"))

;; A row pulses when its transcript grows (new activity), at most once a second a row
;; and never on the first draw that sees it.  It honours `widgetry-flash-style': nil turns it off.
;; pulse.el fades it, one row at a time (it supports no simultaneous pulses).

(defvar claude-board--seen (make-hash-table :test #'equal)
  "Transcript file to (SIZE . TIME of its last pulse).")

(defvar claude-board-pulse-interval 1.0 "Seconds between pulses of one row at most.")

(defface claude-board-pulse '((t :inherit highlight))
  "The start of a row's pulse; its background is set from the theme when it pulses."
  :group 'claude)

(defvar claude-board-pulse-iterations 10 "Steps of a row's fade.")
(defvar claude-board-pulse-delay 0.05 "Seconds between the steps of a row's fade.")
(defvar claude-board-pulse-strength 0.18 "Share of the accent in the start colour of the fade.")

(defun claude-board--pulse-color ()
  "The default background blended a little toward the accent, or nil without
colours."
  (let ((bg (ignore-errors (color-name-to-rgb (face-background 'default nil t))))
        (fg (ignore-errors (color-name-to-rgb (face-foreground 'font-lock-keyword-face nil t)))))
    (when (and bg fg)
      (apply #'color-rgb-to-hex
             (append (cl-mapcar (lambda (b f) (+ (* (- 1 claude-board-pulse-strength) b)
                                                 (* claude-board-pulse-strength f)))
                                bg fg)
                     '(2))))))

(defun claude-board--pulse-row (task)
  "Fade a faint accent out of the row of TASK over about half a second (pulse.el).
The cell of what it just did stays lit a little longer than the row."
  (save-excursion
    (goto-char (point-min))
    (when (text-property-search-forward
           'vtable-object task
           (lambda (a b) (equal (plist-get a :transcript) (plist-get b :transcript))))
      (let ((start (line-beginning-position 0)) (end (line-end-position 0))
            (color (claude-board--pulse-color))
            (pulse-flag t)
            (pulse-iterations claude-board-pulse-iterations)
            (pulse-delay claude-board-pulse-delay))
        (when color (set-face-background 'claude-board-pulse color))
        (pulse-momentary-highlight-region start end 'claude-board-pulse)
        (widgetry-activity-pulse start end)))))

(defun claude-board--pulse (tasks)
  "Pulse the rows of TASKS whose transcript grew since the last draw."
  (let ((now (float-time)))
    (dolist (task tasks)
      (when-let* ((file (plist-get task :transcript))
                  (attrs (file-attributes file)))
        (let* ((size (file-attribute-size attrs))
               (seen (gethash file claude-board--seen))
               (pulse (and seen (> size (car seen)) widgetry-flash-style
                           (> (- now (cdr seen)) claude-board-pulse-interval))))
          (puthash file (cons size (if (or pulse (null seen)) now (cdr seen)))
                   claude-board--seen)
          (when pulse (claude-board--pulse-row task)))))))

;;; Row tags
;; Each row carries its task as a text property, tagged after the table is drawn:
;; the tag, not vtable's row lookup, tells every command which task point is on.

(defun claude-board--tag-rows (tasks start)
  "Tag each row of TASKS with its task, searching from START."
  (save-excursion
    (goto-char start)
    (dolist (task tasks)
      (when-let* ((match (text-property-search-forward 'vtable-object task #'eq)))
        (add-text-properties (prop-match-beginning match) (prop-match-end match)
                             (list 'claude-board-task task))))))

(defun claude-board--task-at-point ()
  "The task of the row at point, from the tag on the text, or nil."
  (or (get-text-property (point) 'claude-board-task)
      (and (not (bobp)) (eolp) (get-text-property (1- (point)) 'claude-board-task))))

(defun claude-board--table (tasks layout)
  "Insert the table of TASKS with the columns of LAYOUT, as wide as the window in
pixels."
  (let* ((char (default-font-width))
         (cells (lambda (task spec)
                  (claude-board--clip (claude-board--cell task (cadr spec)) (caddr spec))))
         (natural (mapcar (lambda (spec)
                            (unless (equal (car spec) "Task")
                              (apply #'max 0 (mapcar (lambda (task)
                                                       (string-pixel-width (funcall cells task spec)
                                                                           (current-buffer)))
                                                     tasks))))
                          layout))
         (widths (claude-board-pixel-widths layout (claude-board--body-pixels) char natural))
         ;; Task is cut to its pixels by the table; this only keeps a long line short
         (layout (cl-mapcar (lambda (spec width)
                              (if (equal (car spec) "Task")
                                  (list (car spec) (cadr spec) (ceiling width char))
                                spec))
                            layout widths))
         (start (point)))
    (make-vtable
     ;; In a terminal a width in px is scaled by the table; there a pixel is a character
     :columns (cl-mapcar (lambda (col width)
                           (list :name (if (equal (car col) "Activity")
                                           (propertize (car col) 'help-echo
                                                       (concat "Activity, newest at the right: "
                                                               (substring-no-properties (claude-board--legend))))
                                         (car col))
                                 :width (if (display-graphic-p) (format "%dpx" width) width)))
                         layout widths)
     :objects tasks
     :getter (lambda (task col _table) (funcall cells task (nth col layout)))
     :separator-width claude-board-column-gap
     :sort-by nil :keymap claude-board-row-map :use-header-line nil)
    ;; The header rounds each column down a little: carry its face to the window's edge
    (save-excursion
      (goto-char start)
      (end-of-line)
      (insert (propertize " " 'display '(space :align-to right) 'face 'header-line)))
    (claude-board--tag-rows tasks start)))

;; The update state shows after the header hint: text a draw computes, since it is read
;; from files and a header line is evaluated at every redisplay.
(defvar-local claude-board--header-status nil "The update state as of the last draw.")

(defun claude-board--header-status ()
  "The update state after a separator, or the empty string; why Recreate is off is
its help."
  (concat (when-let* ((status (ignore-errors (claude-update-status))))
            (propertize (concat " · " status) 'face 'warning))))

(defvar claude-board-heartbeat t
  "Non-nil shows a spinner and the time since the largest stall in the header line.
The spinner stops moving when Emacs does not redraw, which is the point.")

(defvar homun-freeze-watch-largest-gap)
(declare-function claude-errwatch-count-1h "claude-errwatch")
(declare-function claude-errwatch-failed-count "claude-errwatch")
(defvar claude-board--heartbeat-index 0 "Index of the spinner frame shown.")
(defvar claude-board--heartbeat-string "" "The heartbeat as the header line shows it.")

(defun claude-board--heartbeat-text ()
  "The spinner frame and the age of the largest stall, from memory."
  (concat " " (aref widgetry-spinner-frames claude-board--heartbeat-index)
          (when-let* ((gap (bound-and-true-p homun-freeze-watch-largest-gap)))
            (format " largest stall %s (%.1f s)"
                    (claude-board--stall-age (- (float-time) (car gap))) (cdr gap)))
          (when-let* (((fboundp 'claude-errwatch-failed-count))
                      (n (claude-errwatch-count-1h))
                      ((> n 0)))
            (propertize (format " · %d Emacs error%s (1h)" n (if (= n 1) "" "s"))
                        'face (if (> (claude-errwatch-failed-count) 0) 'error 'warning)))))

(defun claude-board--stall-age (seconds)
  "SECONDS as 12s, 3m, 2h or 4d."
  (cond ((< seconds 60) (format "%ds" seconds))
        ((< seconds 3600) (format "%dm" (/ seconds 60)))
        ((< seconds 86400) (format "%dh" (/ seconds 3600)))
        (t (format "%dd" (/ seconds 86400)))))

(defun claude-board--heartbeat-tick (&optional window)
  "Advance the spinner and redraw only the header line of WINDOW."
  (setq claude-board--heartbeat-index
        (mod (1+ claude-board--heartbeat-index) (length widgetry-spinner-frames))
        claude-board--heartbeat-string (claude-board--heartbeat-text))
  (when window (force-mode-line-update)))

(defun claude-board--heartbeat-frame (_snap)
  "Clock client: tick while the board is visible; non-nil to go on."
  (when-let* ((claude-board-heartbeat)
              (window (get-buffer-window "*claude-board*" t)))
    (with-selected-window window (claude-board--heartbeat-tick window))
    t))

(defun claude-board--heartbeat-start ()
  "Register the heartbeat with the clock, at about 4 Hz."
  (homun-clock-register 'claude-board-heartbeat #'claude-board--heartbeat-frame 0.25))

(defun claude-board--header ()
  "The board's `header-line-format'."
  (append (claude-header "Agent board" "RET open · click/i detail · t todo · TAB fold · z fold all · x stop · d detail · SPC m f finished · gr redraw · ? help")
          '((:eval claude-board--header-status)
            (:eval (and claude-board-heartbeat claude-board--heartbeat-string)))))


;;; Alarm trail: the last few messages each role got on the bus
;; One tail per bus/<role>/inbox.jsonl, read on a file-notify change only (no cursor
;; file: the trail starts from the last few KiB at every Emacs start).

(declare-function claude-bus-tail "claude-bus")
(declare-function claude-bus-untail "claude-bus")
(declare-function claude-bus-path "claude-bus")
(declare-function claude-bus-roles "claude-bus")
(defvar claude-bus-dir)

(defvar claude-board-alarms-per-role 3 "Alarms shown per role under the table.")
(defvar claude-board--alarms nil "Alist (ROLE . MESSAGES), newest first, for the trail.")
(defvar claude-board--alarm-tails nil "Alist (ROLE . TAIL) of the inboxes followed.")
(defvar claude-board--alarm-root-watch nil)
(defvar claude-board--alarm-redraws nil "Throttled redraws of the open boards.")

(defun claude-board--alarm-add (role m)
  (let ((cell (or (assoc role claude-board--alarms)
                  (car (push (list role) claude-board--alarms)))))
    (setcdr cell (take claude-board-alarms-per-role (cons m (cdr cell))))
    (mapc #'funcall claude-board--alarm-redraws)))

(defun claude-board--alarm-follow ()
  "Follow the inbox of every role on the bus not followed yet (not Cal's own)."
  (require 'claude-bus)
  (dolist (role (remove "user" (claude-bus-roles)))
    (unless (assoc role claude-board--alarm-tails)
      (ignore-errors
        (push (cons role (claude-bus-tail (claude-bus-path role "inbox.jsonl")
                                          (lambda (m) (claude-board--alarm-add role m))
                                          :backlog 4096))
              claude-board--alarm-tails))))
  (unless claude-board--alarm-root-watch
    (make-directory claude-bus-dir t)
    (setq claude-board--alarm-root-watch
          (file-notify-add-watch claude-bus-dir '(change)
                                 (lambda (_) (claude-board--alarm-follow))))))

(defvar claude-board-alarms-open nil "Non-nil shows the whole alarm trail, else its one summary line.")

(defun claude-board-toggle-alarms ()
  "Show or fold the alarm trail under the table."
  (interactive)
  (setq claude-board-alarms-open (not claude-board-alarms-open))
  (claude-board--draw t))

(defvar claude-board-alarms-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'claude-board-toggle-alarms)
    (define-key map [mouse-1] #'claude-board-toggle-alarms)
    map)
  "Keys on the alarm summary line.")

(defun claude-board--alarm-cut (text width)
  "TEXT on one line, cut to WIDTH characters."
  (truncate-string-to-width (replace-regexp-in-string "\n" " " (or text "")) (max 10 width) nil nil "…"))

(defun claude-board--alarm-trail ()
  "Insert the alarm trail at the end: one dim summary line, the alarms per role
under it when `claude-board-alarms-open'."
  (when claude-board--alarms
    (goto-char (point-max))
    (let* ((all (apply #'append (mapcar #'cdr claude-board--alarms)))
           (latest (car (sort (copy-sequence all)
                              (lambda (a b) (> (or (plist-get a :ts) 0) (or (plist-get b :ts) 0))))))
           (ts (plist-get latest :ts))
           (head (format "  %s Alarms: %d, latest %s "
                         (if claude-board-alarms-open "▾" "▸") (length all)
                         (if (numberp ts) (format-time-string "%H:%M" ts) "--:--"))))
      (unless (bolp) (insert "\n"))
      (insert (propertize (concat head (claude-board--alarm-cut
                                        (plist-get latest :alarm)
                                        (- (claude-board--chars) (length head) 2)))
                          'face 'shadow 'keymap claude-board-alarms-map
                          'mouse-face 'highlight 'help-echo "RET or click: show or fold the alarms")
              "\n")
      (when claude-board-alarms-open
        (dolist (cell (sort (copy-sequence claude-board--alarms)
                            (lambda (a b) (string< (car a) (car b)))))
          (dolist (m (cdr cell))
            (let ((ts (plist-get m :ts)))
              (insert (format "  %-10s %s %-14s %s\n" (car cell)
                              (propertize (if (numberp ts) (format-time-string "%H:%M" ts) "     ")
                                          'face 'shadow)
                              (propertize (or (plist-get m :alarm) "") 'face 'font-lock-keyword-face)
                              (claude-board--alarm-cut (plist-get m :msg)
                                                       (- (claude-board--chars) 38)))))))))))

(defvar-local claude-board--signature nil "What the last draw showed, to skip a draw that would show the same.")

(defun claude-board--signature (tasks layout)
  "Everything the board shows, as data: equal data means a redraw would change
nothing.
Call it inside a draw, where the rows are cached."
  (let ((main (claude-board--main tasks)))
    (list layout (claude-board--pixels) claude-board--finished
          claude-board-visible-columns claude-board-activity-detail
          (mapcar (lambda (task) (list (claude-board--row task) (claude-board--last-line task)))
                  tasks)
          (claude-board--usage)
          (and main (claude-board--context (plist-get main :transcript)))
          (and main (claude-board--homun-state main))
          claude-board--requests
          claude-board--alarms claude-board-alarms-open
          (ignore-errors (claude-update-status))
          (ignore-errors (claude-update-pending-label)))))

(defun claude-board--draw (&optional force)
  "Redraw the board, keeping the top of the window and point on the selected task.
Nothing happens when what it shows is as it was, unless FORCE."
  (let* ((tasks (claude-board--tree (append (claude-board--mains) (claude-board--handoffs) (claude-board--tasks))))
         (window (get-buffer-window nil t))
         (top (and window (line-number-at-pos (window-start window))))
         (inhibit-read-only t)
         (layout (claude-board-layout (claude-board--chars)))
         (claude-board--drawing t)
         (claude-board--requests (claude-board--read-requests))
         (claude-board--rows (make-hash-table :test #'eq))
         (signature (claude-board--signature tasks layout)))
    (setq claude-board--width (claude-board--pixels)
          claude-board--header-status (claude-board--header-status)
          ;; The header names the board and the Activity heading's help holds the legend
          mode-line-format nil)
    (claude-board--watch (current-buffer))
    ;; Looked and found it current: the header's time and stale badge count from here
    (claude-touch)
    (setq claude-stale-after (* 6 claude-board-interval))
    (if (and (not force) (equal-including-properties signature claude-board--signature))
        (claude-board--pulse tasks)
      (setq claude-board--signature signature)
      (erase-buffer)
      (claude-board--meters (claude-board--main tasks))
      (if (null tasks)
          (insert (propertize "\n  No agents or jobs running.\n" 'face 'shadow))
        (claude-board--table tasks layout))
      (claude-board--alarm-trail)
      (claude-board--goto-selected tasks)
      (claude-board--pulse tasks)
      (widgetry-activity-blink)
      ;; Erasing the buffer sent every window's point to the top: windows other
      ;; than the selected one keep their own point, so set theirs too
      (dolist (w (get-buffer-window-list nil nil t))
        (homun-layout-point w (point)))
      (when window
        (homun-layout-point window nil (save-excursion (goto-char (point-min))
                                                        (forward-line (1- top)) (point)))))))

(defun claude-board--refresh (buffer)
  (when (and (buffer-live-p buffer) (get-buffer-window buffer t))
    (with-current-buffer buffer (claude-board--draw))))

;; The timed redraw is a client of `homun-clock', which has the only timer: it is called every
;; frame and redraws the board once `claude-board-interval' has passed, while the board is shown.

(defun claude-board--frame (buffer)
  "The clock client of the board BUFFER: redraw it when its interval passed.
Return non-nil while the buffer lives."
  (when (buffer-live-p buffer)
    (let ((now (float-time)))
      (when (>= (- now (buffer-local-value 'claude-board--timer buffer)) claude-board-interval)
        (with-current-buffer buffer (setq claude-board--timer now))
        (claude-board--refresh buffer)))
    t))

(defun claude-board--watch (buffer)
  "Have the clock redraw BUFFER every `claude-board-interval' seconds."
  (claude-board--heartbeat-start)
  (unless (buffer-local-value 'claude-board--timer buffer)
    (with-current-buffer buffer (setq claude-board--timer (float-time)))
    (homun-clock-register (cons 'claude-board buffer)
                          (lambda (_snap) (claude-board--frame buffer))
                          claude-board-interval)))

(defun claude-board--task ()
  "The task of the row at point."
  (or (claude-board--task-at-point) (user-error "No task here")))

(declare-function claude-cockpit "claude-homun")
(declare-function claude-transcript-buffer "claude-transcript")
(autoload 'claude-settings "claude-settings" "Show the settings page." t)

(defun claude-board--kill-agent-transcripts (keep)
  "Kill the transcript buffers of agents other than the one in file KEEP: one is
open at a time."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'claude-transcript-mode)
                 (boundp 'claude-transcript--file)
                 (stringp claude-transcript--file)
                 (string-match-p "/subagents/" claude-transcript--file)
                 (not (equal claude-transcript--file keep))
                 (not (get-buffer-window buffer t)))
        (kill-buffer buffer)))))

(declare-function homun-stage-agent-open "homun-stage-agent")
(autoload 'claude-agent-view-open "claude-agent-view")
(autoload 'claude-agent-view-leave "claude-agent-view" nil t)
(autoload 'claude-workflow-open "claude-workflow" "Show a workflow run in the side window.")

(cl-defun claude-board-open ()
  "Show the transcript (claude-transcript viewer) of the task at point."
  (interactive)
  (claude-board--remember)
  (unless (or (claude-board--task) (null (claude-update-status)))
    (claude-update-open)
    (cl-return-from claude-board-open))
  (when-let* ((name (plist-get (claude-board--task) :handoff)))
    (claude-handoff-open name)
    (cl-return-from claude-board-open))
  (when-let* ((run (and (eq (plist-get (claude-board--task) :kind) 'workflow)
                        (plist-get (claude-board--task) :run))))
    (claude-workflow-open run)
    (cl-return-from claude-board-open))
  (let ((file (plist-get (claude-board--task) :transcript)))
    (unless file (user-error "This task has no transcript"))
    ;; A subagent's transcript in the transcript window
    (when (string-search "/subagents/" file)
      (claude-agent-view-open file)
      (cl-return-from claude-board-open))
    (claude-agent-view-leave)
    (require 'claude-transcript nil t)
    (if (fboundp 'claude-transcript-open)
        ;; Into the window already showing a transcript, keeping the user's layout;
        ;; the standard layout (claude-cockpit) only when there is none yet
        (if-let* ((window (seq-find (lambda (window)
                                      (with-current-buffer (window-buffer window)
                                        (derived-mode-p 'claude-transcript-mode)))
                                    (window-list nil 'no-minibuf))))
            (select-window (homun-layout-show (claude-transcript-buffer file) window))
          (claude-cockpit file))
      (user-error "claude-transcript is not loaded"))
    (claude-board--kill-agent-transcripts file)))

(defun claude-board-detail ()
  "Show the detail of the task at point: its tracker item and agent run."
  (interactive)
  (require 'claude-task-detail)
  (claude-board--remember)
  (claude-task-detail-open (claude-board--task)))

(defun claude-board-stop ()
  "Stop the task at point: a headless one over its stream, else ask the manager."
  (interactive)
  (let ((task (claude-board--task)))
    (if-let* ((name (plist-get task :handoff)))
        (when (claude-confirm (format "Stop the handoff %s (it writes a summary first)? " name))
          (claude-handoff-stop name))
      (when (claude-confirm (if (plist-get task :stream)
                           (format "Stop %s? " (plist-get task :desc))
                         (format "Ask %s to stop %s? " claude-agent-name (plist-get task :desc))))
        (claude-tasks--stop task)))))

(defun claude-board-open-todo ()
  "Show the todo heading the agent at point is linked to."
  (interactive)
  (claude-links-open-todo (plist-get (claude-board--task) :id)))

(defun claude-board-toggle-finished ()
  "Show or hide the subagents that finished today."
  (interactive)
  (setq claude-board--finished (not claude-board--finished))
  (claude-board--draw))

(declare-function claude-settings-set "claude-settings")

(defun claude-board-toggle-activity-detail ()
  "Name each row's latest activity next to its strip, or only show the strip.
The choice is the setting `claude-board-activity-detail' and is kept."
  (interactive)
  ;; Setting it redraws the board
  (require 'claude-settings)
  (claude-settings-set 'claude-board-activity-detail (not claude-board-activity-detail)))

(defun claude-board-toggle-column ()
  "Ask which optional column to show or hide; the choice is a setting and is kept."
  (interactive)
  (require 'claude-settings)
  (let* ((keys '((?t "type" "Type" type) (?m "model" "Model" model) (?a "age" "Age" age)
                 (?c "context" "Context" context) (?v "activity" "Activity" activity)))
         (choice (read-multiple-choice
                  (format "Toggle column (shown: %s)"
                          (mapconcat #'symbol-name claude-board-visible-columns " "))
                  (mapcar (lambda (k) (list (car k) (cadr k))) keys)))
         (column (nth 3 (assq (car choice) keys))))
    (claude-settings-set 'claude-board-visible-columns
                         (seq-filter (lambda (c) (if (eq c column)
                                                     (not (memq c claude-board-visible-columns))
                                                   (memq c claude-board-visible-columns)))
                                     claude-board-optional-columns))))

(defvar claude-board-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'claude-board-open)
    (define-key map "d" #'claude-board-toggle-activity-detail)
    (define-key map "c" #'claude-board-toggle-column)
    (define-key map "f" #'claude-board-toggle-finished)
    (define-key map "x" #'claude-board-stop)
    (define-key map "t" #'claude-board-open-todo)
    (define-key map "i" #'claude-board-detail)
    (define-key map "U" #'claude-update)
    (define-key map "R" #'claude-update-restart)
    (homun-bind-common map #'revert-buffer)
    (define-key map "?" #'homun-menu-board)
    map))

(declare-function evil-define-key* "evil-core")
(with-eval-after-load 'evil
  (evil-define-key* '(normal motion) claude-board-mode-map
    (kbd "RET") #'claude-board-open
    (kbd "x") #'claude-board-stop
    (kbd "t") #'claude-board-open-todo
    (kbd "i") #'claude-board-detail
    (kbd "d") #'claude-board-toggle-activity-detail
    (kbd "c") #'claude-board-toggle-column
    (kbd "D") #'claude-board-stop
    (kbd "U") #'claude-update
    (kbd "R") #'claude-update-restart
    (kbd "?") #'homun-menu-board)
  ;; f is evil's find-char: finished goes under the local leader
  (homun-bind-leader 'claude-board-mode 'claude-board-mode-map
                     '(("f" . claude-board-toggle-finished) ("u" . claude-update-open))))

;;;; C-j / C-k from any cockpit buffer: select the next or previous agent on the board

(defun claude-board--other-row (direction)
  "In the board buffer: the position of the row DIRECTION (1 or -1) away from the
selected one, or nil."
  (let* ((window (get-buffer-window (current-buffer) t))
         (pos (if window (window-point window) (point)))
         (here (save-excursion (goto-char pos) (claude-board--task-at-point))))
    (save-excursion
      (goto-char pos)
      (let (found)
        (while (and (not found) (zerop (forward-line direction)))
          (let ((task (claude-board--task-at-point)))
            (when (and task (not (eq task here)) (plist-get task :transcript))
              (setq found (point)))))
        found))))

(defun claude-board--follow-selection (task)
  "Show TASK in the side agent view or the transcript window, if one is on screen;
no focus change."
  (let ((file (plist-get task :transcript))
        (agent (seq-some (lambda (w) (string-prefix-p "*stage agent-" (buffer-name (window-buffer w))))
                         (window-list nil 'never))))
    (save-selected-window
      (cond ((and file (string-search "/subagents/" file))
             (when agent
               (require 'homun-stage-agent)
               (homun-stage-agent-open file)))
            ((and file (not (plist-get task :handoff))
                  (require 'claude-transcript nil t)
                  (fboundp 'claude-transcript-open))
             (when-let* ((window (seq-find (lambda (w)
                                             (with-current-buffer (window-buffer w)
                                               (derived-mode-p 'claude-transcript-mode)))
                                           (window-list nil 'no-minibuf))))
               (homun-layout-show (claude-transcript-buffer file) window)))))))

(defun claude-board-select (direction)
  "Move the board's selected row DIRECTION (1 down, -1 up) from any buffer; no
focus change."
  (let ((buffer (get-buffer "*claude-board*")))
    (unless buffer (user-error "No board"))
    (with-current-buffer buffer
      (if-let* ((pos (claude-board--other-row direction)))
          (let ((window (get-buffer-window buffer t)))
            (goto-char pos)
            (when window
              (homun-layout-point window pos)
              (with-selected-window window (recenter nil) (redisplay)))
            (claude-board--remember)
            (when-let* ((task (claude-board--task-at-point)))
              (claude-board--follow-selection task)))
        (message "No %s agent" (if (> direction 0) "next" "previous"))))))

(defun claude-board-select-next ()
  "Select the next agent down the board, from any cockpit buffer."
  (interactive)
  (claude-board-select 1))

(defun claude-board-select-previous ()
  "Select the previous agent up the board, from any cockpit buffer."
  (interactive)
  (claude-board-select -1))

(defvar claude-board-select-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-j") #'claude-board-select-next)
    (define-key map (kbd "C-k") #'claude-board-select-previous)
    map))

(define-minor-mode claude-board-select-mode
  "C-j and C-k select the next and previous agent on the board."
  :lighter nil :keymap claude-board-select-mode-map)

(declare-function evil-define-minor-mode-key "evil-core")
(with-eval-after-load 'evil
  (evil-define-minor-mode-key '(normal motion insert) 'claude-board-select-mode
    (kbd "C-j") #'claude-board-select-next
    (kbd "C-k") #'claude-board-select-previous))

(defconst claude-board-select-modes
  '(claude-transcript-mode claude-compose-mode claude-board-mode homun-stage-mode
    claude-todos-view-mode claude-agent-mode claude-agent-tasks-mode
    claude-update-mode claude-follow-mode
    claude-events-mode)
  "Cockpit modes that get `claude-board-select-mode'.")

(dolist (mode claude-board-select-modes)
  (add-hook (intern (format "%s-hook" mode)) #'claude-board-select-mode))
(dolist (buffer (buffer-list))
  (with-current-buffer buffer
    (when (apply #'derived-mode-p claude-board-select-modes)
      (claude-board-select-mode 1))
    (when (and (boundp 'claude-compose-mode) claude-compose-mode)
      (claude-board-select-mode 1))))

;; The throttle is per board (made once in `claude-board--watch-files').
(defvar-local claude-board--redraw nil "Throttled redraw of this board.")

;; A change of the window's width redraws the board, but never from inside the
;; hook: that runs during redisplay, where a redraw can change the window again
;; and call the hook again.  The hook only starts one idle timer, and the timer
;; redraws when the body width in pixels still differs from the last draw.
(defvar claude-board-resize-delay 0.1 "Idle seconds after a resize before the board redraws.")
(defvar-local claude-board--resize-timer nil "The pending redraw after a resize, or nil.")

(defun claude-board--pixels ()
  "Body width in pixels of the board's window, or nil without one."
  (when-let* ((window (get-buffer-window nil t)))
    (window-body-width window t)))

(defun claude-board--resized-p ()
  "Non-nil when the board's window is not as wide as at the last draw."
  (when-let* ((pixels (claude-board--pixels)))
    (not (eql pixels claude-board--width))))

(defun claude-board--resized (&rest _)
  "Schedule one redraw when the board's window changed width (a local
`window-size-change-functions' hook).  Nothing is drawn here."
  (when (and (not claude-board--drawing) (not claude-board--resize-timer)
             (claude-board--resized-p))
    (setq claude-board--resize-timer
          (run-with-idle-timer claude-board-resize-delay nil
                               #'claude-board--resize-redraw (current-buffer)))))

(defun claude-board--resize-redraw (buffer)
  "Redraw the board BUFFER if its window still differs from the last draw."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq claude-board--resize-timer nil)
      (when (and (not claude-board--drawing) (claude-board--resized-p))
        (claude-board--draw)))))

(define-derived-mode claude-board-mode special-mode "Board"
  "Running agents and jobs.  C-j/C-k select the next/previous agent (from any
cockpit buffer), RET open, t the agent's todo, x or D stop (asks first), d
activity in detail, c columns, TAB fold the last line, z fold all, SPC m f
finished (f without evil), gr redraw."
  (add-hook 'post-command-hook #'claude-board--remember nil t)
  (setq-local bidi-paragraph-direction 'left-to-right bidi-inhibit-bpa t)
  (add-hook 'window-size-change-functions #'claude-board--resized nil t)
  (setq-local revert-buffer-function (lambda (&rest _) (claude-board--draw t))
              header-line-format (claude-board--header)))

(defun claude-board--watch-files (buffer)
  "Redraw BUFFER, throttled, when files under the task directories change.
Once per buffer: a second call does nothing, so watches and throttles never pile
up."
  (unless (buffer-local-value 'claude-board--redraw buffer)
  (let ((redraw (timeout-throttled-func
                 (lambda () (claude-board--refresh buffer)) claude-board-throttle)))
    (with-current-buffer buffer
      (setq claude-board--redraw redraw)
      (push redraw claude-board--alarm-redraws)
      (ignore-errors (claude-board--alarm-follow))
      (dolist (dir (list claude-tasks-jobs-dir claude-tasks-watch-dir
                         (file-name-directory claude-tasks-ledger)
                         ;; A permission request shows as a wait in its row's activity
                         (expand-file-name "requests/" (bound-and-true-p claude-approve-dir))))
        (when (file-directory-p dir)
          (push (file-notify-add-watch dir '(change) (lambda (_) (funcall redraw)))
                claude-board--watches)))
      (add-hook 'kill-buffer-hook
                (lambda ()
                  (mapc #'file-notify-rm-watch claude-board--watches)
                  (setq claude-board--alarm-redraws (delq redraw claude-board--alarm-redraws)))
                nil t)))))

;;;###autoload
(defun claude-board ()
  "Show the running agents and jobs in a live table."
  (interactive)
  (let ((buffer (get-buffer-create "*claude-board*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'claude-board-mode)
        (claude-board-mode)
        (claude-board--watch-files buffer))
      (claude-board--draw))
    (pop-to-buffer buffer)))

;; A reload gives a board that is already open the header as it is now
(when-let* ((buffer (get-buffer "*claude-board*")))
  (with-current-buffer buffer
    (when (derived-mode-p 'claude-board-mode)
      (setq header-line-format (claude-board--header))
      ;; a board from before the fix may hold a pile of watches and throttles: one of each
      (when (cdr claude-board--alarm-redraws)
        (mapc #'file-notify-rm-watch claude-board--watches)
        (setq claude-board--watches nil claude-board--redraw nil claude-board--alarm-redraws nil)
        (claude-board--watch-files buffer))
      ;; and the alarm trail a board opened before it had
      (when (and claude-board--redraw (not (memq claude-board--redraw claude-board--alarm-redraws)))
        (push claude-board--redraw claude-board--alarm-redraws))
      (ignore-errors (claude-board--alarm-follow)))))

(provide 'claude-board)
;;; claude-board.el ends here
