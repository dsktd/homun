;;; claude-links.el --- Agents tied to tasks: the links store and its events -*- lexical-binding: t -*-

;; An agent is linked to a task for as long as it runs: a heading of the main
;; session's todos (`claude-todos-file') or a tracker item.  The links are in
;; `claude-links-file', one JSON row per agent, written only by the
;; claude-task-links script; this file tells it what happened and reads the rows.
;;
;; The events come from what is on disk already: the main session's transcript
;; (the background agents `claude-tasks--background' finds) and the streams of
;; headless sessions (`task_started' and `task_notification' lines).  Every
;; `claude-links-interval' seconds the agents found are compared with the store:
;; a running agent without a row starts a link, an ended one with an open row
;; ends it.  Nothing is remembered here, so a restart of Emacs repeats nothing.
;;
;; `claude-links-open-todo' goes from an agent to its heading, and the
;; homun-agent: links the script writes into the heading's :AGENT: property
;; come back with `claude-links-open-agent'.

(require 'homun-dir)
(require 'claude)
(require 'claude-agent)
(require 'claude-tasks)
(require 'claude-todos)
(require 'ol)

(defvar claude-links-file (expand-file-name "~/claude/.services/tasks/links.jsonl")
  "The links store: one JSON row per agent.")

(defvar claude-links-command nil
  "The writer of the store, as a command; nil for the script of this Elisp's
checkout.
It reads events from stdin, one JSON object per line.")

(defun claude-links--command ()
  "The command of the writer: the script next to this library's directory.
Found when called, so the two always come from one checkout."
  (or claude-links-command
      (list "python3"
            (expand-file-name "../claude-task-links"
                              homun-cockpit-dir)
            "apply")))

(defvar claude-links-stream-globs '("~/claude/.services/*/stream/stream.jsonl"
                                    "~/claude/.services/x1/stream.jsonl")
  "Where the brokers of headless sessions write their streams.")

(defvar claude-links-interval 10 "Seconds between two comparisons of the agents with the store.")

;;; The store

(defvar claude-links--rows nil "(MTIME . TABLE): the store as last read, agent id to its row.")

(defun claude-links-rows ()
  "The store as a hash table of agent id to its row (an alist); read when it
changed."
  (let ((mtime (file-attribute-modification-time (file-attributes claude-links-file))))
    (unless (and claude-links--rows (equal mtime (car claude-links--rows)))
      (let ((table (make-hash-table :test #'equal)))
        (when mtime
          (with-temp-buffer
            (insert-file-contents claude-links-file)
            (while (not (eobp))
              (when-let* ((row (ignore-errors
                                 (json-parse-string
                                  (buffer-substring (point) (line-end-position))
                                  :object-type 'alist :array-type 'list :null-object nil))))
                (puthash (alist-get 'agent row) row table))
              (forward-line 1))))
        (setq claude-links--rows (cons mtime table))))
    (cdr claude-links--rows)))

(defun claude-links-row (agent)
  "The row of the agent with id AGENT, or nil."
  (gethash agent (claude-links-rows)))

;;; Agents of headless streams

(defvar claude-links--streams (make-hash-table :test #'equal)
  "Stream FILE -> (OFFSET . TASKS): the bytes read so far and agent id to plist.")

(defun claude-links--stream-entry (entry tasks)
  "Record in TASKS what the stream ENTRY says about an agent."
  (let-alist entry
    (pcase .subtype
      ((and "task_started" (guard (equal .task_type "local_agent")))
       (puthash .task_id (list :id .task_id :status 'running :session .session_id
                               :desc (or .description (format "agent %s" .task_id))
                               :task (claude-tasks--task-id .prompt))
                tasks))
      ;; A stream is rotated, so the start of an agent may be gone: its end still counts
      ("task_notification"
       (puthash .task_id
                (append (list :id .task_id :summary .summary :session .session_id
                              :status (pcase .status
                                        ("completed" 'done) ("failed" 'failed) (_ 'stopped)))
                        (gethash .task_id tasks))
                tasks)))))

(defun claude-links--stream-agents (file)
  "The agents the headless stream FILE has named so far, as task plists."
  (let* ((fresh (lambda () (puthash file (cons 0 (make-hash-table :test #'equal))
                                    claude-links--streams)))
         (state (or (gethash file claude-links--streams) (funcall fresh))))
    (when (< (or (file-attribute-size (file-attributes file)) 0) (car state))
      (setq state (funcall fresh)))
    (setcar state (claude-tasks--tail
                   file (car state) "\"task_started\"\\|\"task_notification\""
                   (lambda (entry) (claude-links--stream-entry entry (cdr state)))))
    (hash-table-values (cdr state))))

;;; Events

(defun claude-links--agents ()
  "Every agent the main session's transcript and the headless streams name."
  (append
   (when-let* ((id (claude-main-session-id))
               (main (claude-agent--session-transcript id)))
     (seq-filter (lambda (task) (eq (plist-get task :kind) 'agent))
                 (claude-tasks--background main)))
   (seq-mapcat #'claude-links--stream-agents
               (seq-mapcat (lambda (glob) (file-expand-wildcards (expand-file-name glob)))
                           claude-links-stream-globs))))

(defun claude-links--transcript (agent)
  "The transcript file of the agent with id AGENT, or nil."
  (car (claude-agent--glob (format "*/*/subagents/agent-%s.jsonl" agent))))

(defun claude-links-events (agents)
  "The events that bring the store up to date with AGENTS, a list of task plists.
A running agent the store does not know starts; one that ended while its row
is open ends.  An agent that ended before it was ever stored is left out."
  (let ((todos (claude-todos-file)))
    (seq-keep
     (lambda (task)
       (let* ((id (plist-get task :id))
              (row (claude-links-row id))
              (status (plist-get task :status))
              (time (lambda (key) (and (plist-get task key) (floor (plist-get task key))))))
         (cond
          ((and (null row) (eq status 'running))
           `((event . "start") (agent . ,id) (desc . ,(plist-get task :desc))
             (task . ,(plist-get task :task)) (at . ,(funcall time :started))
             (session . ,(plist-get task :session)) (todos . ,todos)))
          ((and row (null (alist-get 'end row)) (not (eq status 'running)))
           `((event . "end") (agent . ,id) (status . ,(symbol-name status))
             (at . ,(funcall time :ended)) (summary . ,(plist-get task :summary))
             (transcript . ,(claude-links--transcript id)) (todos . ,todos))))))
     agents)))

(defvar claude-links--process nil "The running writer, or nil.")

(defun claude-links-sync ()
  "Send the writer what changed since the store was written; redraw the board
after."
  (unless (process-live-p claude-links--process)
    (when-let* ((events (claude-links-events (claude-links--agents))))
      (setq claude-links--process
            (make-process
             :name "claude-task-links" :noquery t :buffer nil :connection-type 'pipe
             :command (claude-links--command)
             :sentinel (lambda (process _event)
                         (unless (process-live-p process)
                           (when-let* ((board (get-buffer "*claude-board*"))
                                       ((fboundp 'claude-board--refresh)))
                             (claude-board--refresh board))))))
      (process-send-string
       claude-links--process
       (mapconcat (lambda (event)
                    (concat (json-serialize (seq-filter #'cdr event)) "\n"))
                  events))
      (process-send-eof claude-links--process))))

(defvar claude-links--timer nil "The timer of `claude-links-sync'.")

(defun claude-links-start ()
  "Compare the agents with the store every `claude-links-interval' seconds."
  (when (timerp claude-links--timer) (cancel-timer claude-links--timer))
  (setq claude-links--timer
        (run-with-timer claude-links-interval claude-links-interval
                        (lambda () (with-demoted-errors "claude-links: %S" (claude-links-sync))))))

(unless noninteractive (claude-links-start))

;;; Between an agent and its heading

(defun claude-links-open-todo (agent)
  "Show the todo heading the agent with id AGENT is linked to."
  (claude-todos)
  (let ((found (save-excursion
                 (goto-char (point-min))
                 (and (search-forward (format "[[homun-agent:%s]]" agent) nil t)
                      (progn (org-back-to-heading t) (point))))))
    (unless found
      (user-error "No todo is linked to this agent%s"
                  (if-let* ((row (claude-links-row agent))
                            ((equal (alist-get 'kind row) "tracker")))
                      (format " (tracker item %s)" (alist-get 'task row))
                    "")))
    (goto-char found)
    (org-fold-show-context 'agenda)
    (recenter 2)))

(declare-function claude-transcript-open "claude-transcript")

(defun claude-links-open-agent (agent &optional _prefix)
  "Go to the board's row of the agent with id AGENT, or open its transcript without
one."
  (let* ((board (get-buffer "*claude-board*"))
         (window (and board (get-buffer-window board)))
         (row (and window
                   (with-selected-window window
                     (goto-char (point-min))
                     (text-property-search-forward
                      'claude-board-task agent
                      (lambda (id task) (equal id (plist-get task :id))))))))
    (cond
     (row (select-window window)
          (goto-char (prop-match-beginning row)))
     ((claude-links--transcript agent)
      (require 'claude-transcript)
      (claude-transcript-open (claude-links--transcript agent)))
     (t (user-error "Agent %s has no row and no transcript" agent)))))

(org-link-set-parameters "homun-agent" :follow #'claude-links-open-agent)

(provide 'claude-links)
;;; claude-links.el ends here
