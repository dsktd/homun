;;; homun-stage-agent.el --- The `agent' preset: a subagent's work, live on the Stage -*- lexical-binding: t -*-

;; `homun-stage-agent-open' shows the subagent whose transcript is FILE as a scene: a title bound
;; to agent.<id>.head and its steps (prose, commands with their output, edits as -/+ lines)
;; bound to agent.<id>.steps.  A clock client reads what the transcript gained and publishes both.
;; `homun-stage-agent-open-role' shows a headless role's stream (stream.jsonl of the session broker)
;; the same way, plus the block being written now, bound to agent.<id>.live
;; and redrawn at the clock's period, not per token.  Thinking, subagent tasks, results, rate
;; limits and session notes become steps; a record no branch knows is counted in the head and
;; appended to the stream's unhandled.jsonl, so none is dropped unseen.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'homun-clock)
(require 'homun-stage-store)
(require 'homun-stage-bind)

(defvar homun-stage-agent-period 3 "Seconds between looks at a transcript.")
(defvar homun-stage-agent-live-period 0.5 "Seconds between looks at a live stream.")
(defvar homun-stage-agent-live-chars 4000 "Characters of the block in progress shown.")
(defvar homun-stage-agent-turns 3 "Finished turns of a stream shown when it is opened.")
(defvar homun-stage-agent-steps 300 "How many of the newest steps are drawn.")
(defvar homun-stage-agent-output-lines 12 "Last lines of a command's output shown.")
(defvar homun-stage-agent-write-lines 20 "Lines of a new file shown.")

(defvar homun-stage-agent--runs (make-hash-table :test #'equal)
  "Scene id to its run: a plist :file :offset :brief :steps (newest first)
:results.")

(defun homun-stage-agent--id (file)
  (downcase (substring (file-name-base file) 0 (min 64 (length (file-name-base file))))))

(defun homun-stage-agent--read (file from)
  "The records of FILE after byte FROM, up to its last newline, and the new offset."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil from)
    (let ((end (progn (goto-char (point-max)) (if (search-backward "\n" nil t) (1+ (point)) (point-min))))
          records)
      (goto-char (point-min))
      (while (< (point) end)
        (let* ((line (decode-coding-string
                      (buffer-substring-no-properties (point) (line-end-position)) 'utf-8))
               (rec (ignore-errors
                      (json-parse-string line :object-type 'alist :array-type 'list
                                         :null-object nil :false-object nil))))
          (push (if (and rec (listp rec)) rec `((type . "unparsed") (raw . ,line))) records))
        (forward-line 1))
      (cons (nreverse records) (+ from (1- end))))))

(defun homun-stage-agent--text (content)
  (if (stringp content) content
    (mapconcat (lambda (p) (or (and (listp p) (stringp (alist-get 'text p)) (alist-get 'text p)) ""))
               content "")))

(defun homun-stage-agent--ask (run text)
  "TEXT is a user message: the brief of RUN if it has none, else a step."
  (if (plist-get run :brief)
      (plist-put run :steps (cons (list 'ask (string-trim text)) (plist-get run :steps)))
    (plist-put run :brief text)))

(defvar homun-stage-agent-folded
  '("stream_event/content_block_delta/input_json_delta" "stream_event/content_block_delta/signature_delta"
    "stream_event/content_block_stop" "stream_event/message_start" "stream_event/message_delta"
    "stream_event/message_stop" "stream_event/ping" "system/thinking_tokens" "system/status"
    "system/hook_started" "system/permission_check_status" "system/task_updated" "system/task_progress"
    "system/background_tasks_changed" "system/commands_changed" "control_request" "control_response"
    "control_cancel_request" "keep_alive" "tool_progress"
    ;; a subagent transcript's own bookkeeping
    "attachment" "api-request" "api-request-blob" "api-request-shape" "data-flow-records"
    "file-history-snapshot" "summary" "queue-operation" "progress" "last-prompt" "custom-title")
  "Kinds whose content another record carries; see
design/homun-generic/experiments/headless/events.md.")

(defvar homun-stage-agent-unhandled-cap (* 1024 1024)
  "Bytes of an unhandled log before it is moved to .1.")

(defun homun-stage-agent--kind (rec)
  "type/subtype of REC; for a stream event its event type and delta type."
  (let ((type (or (alist-get 'type rec) "?")))
    (if (equal type "stream_event")
        (let ((event (alist-get 'event rec)))
          (string-join (delq nil (list type (alist-get 'type event)
                                       (alist-get 'type (alist-get 'delta event))))
                       "/"))
      (if-let* ((sub (alist-get 'subtype rec))) (format "%s/%s" type sub) type))))

(defun homun-stage-agent--unhandled (run rec kind)
  "Count REC (of KIND) as unhandled in RUN and append it to RUN's :log."
  (plist-put run :unhandled (1+ (or (plist-get run :unhandled) 0)))
  (when-let* ((log (plist-get run :log)))
    (ignore-errors
      (when (> (or (file-attribute-size (file-attributes log)) 0) homun-stage-agent-unhandled-cap)
        (rename-file log (concat log ".1") t))
      (let ((raw (json-encode rec)))
        (write-region
         (concat (json-encode `((type . ,(alist-get 'type rec)) (subtype . ,(cadr (split-string kind "/")))
                                (ts . ,(or (alist-get 'ts rec) (float-time))) (by . "stage-agent")
                                (raw . ,(substring raw 0 (min 2000 (length raw))))))
                 "\n")
         nil log t 'silent)))))

(defun homun-stage-agent--note (run text &optional face)
  (plist-put run :steps (cons (list 'note text (or face 'shadow)) (plist-get run :steps))))

(defun homun-stage-agent--delta (run event)
  "Grow the live block of RUN by the stream EVENT."
  (let-alist event
    (pcase .type
      ("content_block_start"
       (plist-put run :live (pcase .content_block.type
                              ("tool_use" (format "%s " .content_block.name))
                              ("thinking" "∴ ")
                              (_ ""))))
      ("content_block_delta"
       (when-let* ((more (or .delta.text .delta.thinking .delta.partial_json)))
         (plist-put run :live (concat (plist-get run :live) more)))))))

(defun homun-stage-agent--limits (info)
  "The windows of a rate limit INFO as \"5h 83% 7d 40%\"."
  (mapconcat (lambda (w)
               (format "%s %d%%" (pcase (car w) ('five_hour "5h") ('seven_day "7d") (n n))
                       (round (* 100 (or (alist-get 'utilization (cdr w)) 0)))))
             (alist-get 'unifiedWindows info) " "))

(defun homun-stage-agent--fold (run records)
  "Fold RECORDS into RUN, destructively.
A record no branch knows is counted and kept in RUN's unhandled log."
  (dolist (rec records)
    (let* ((message (alist-get 'message rec))
           (content (and (consp message) (alist-get 'content message)))
           (kind (homun-stage-agent--kind rec)))
      (unless (string-prefix-p "stream_event" kind) (plist-put run :dirty t))
      (let-alist rec
        (cond
         ;; a subagent's own records end in its task_notification
         ((or .parent_tool_use_id (member kind homun-stage-agent-folded)))
         ((string-prefix-p "stream_event/" kind) (homun-stage-agent--delta run .event))
         ((string-prefix-p "result" kind)
          (plist-put run :live "")
          (homun-stage-agent--note
           run (format "%s · $%.4f · %.1f s · %s out"
                       (if (and (equal .subtype "success") (not .is_error)) "done"
                         (string-trim (format "■ %s %s" .subtype (or .terminal_reason ""))))
                       (or .total_cost_usd 0) (/ (or .duration_ms 0) 1000.0) (or .usage.output_tokens 0))
           (if (and (equal .subtype "success") (not .is_error)) 'shadow 'error)))
         ((equal kind "rate_limit_event")
          (plist-put run :limits (homun-stage-agent--limits .rate_limit_info))
          (unless (member .rate_limit_info.status '("allowed" nil))
            (homun-stage-agent--note run (format "rate limit %s: %s" .rate_limit_info.rateLimitType
                                                 .rate_limit_info.status)
                                     'warning)))
         ((equal kind "user")
          (if (stringp content)
              (homun-stage-agent--ask run content)
            (dolist (part content)
              (pcase (alist-get 'type part)
                ("text" (homun-stage-agent--ask run (alist-get 'text part)))
                ("tool_result"
                 (puthash (alist-get 'tool_use_id part)
                          (list (homun-stage-agent--text (alist-get 'content part))
                                (alist-get 'is_error part) .toolUseResult)
                          (plist-get run :results)))))))
         ((equal kind "assistant")
          (plist-put run :live "")
          (dolist (part (and (listp content) content))
            (pcase (alist-get 'type part)
              ("thinking" (unless (string-blank-p (or (alist-get 'thinking part) ""))
                            (plist-put run :steps (cons (list 'think (string-trim (alist-get 'thinking part)))
                                                        (plist-get run :steps)))))
              ("text" (unless (string-blank-p (alist-get 'text part))
                        (plist-put run :steps (cons (list 'prose (string-trim (alist-get 'text part)))
                                                    (plist-get run :steps)))))
              ("tool_use" (plist-put run :steps (cons (list 'tool (alist-get 'id part) (alist-get 'name part)
                                                            (alist-get 'input part))
                                                      (plist-get run :steps)))))))
         ((equal kind "system/init") (homun-stage-agent--note run (format "session %s · %s" .model .cwd)))
         ((equal kind "system/task_started")
          (homun-stage-agent--note run (format "⇢ %s: %s" (or .subagent_type .task_type) .description)))
         ((equal kind "system/task_notification")
          (homun-stage-agent--note
           run (format "⇠ %s %s%s" .description .status
                       (if .usage.total_tokens (format " · %d tok" .usage.total_tokens) ""))
           (if (member .status '("completed" nil)) 'shadow 'error)))
         ((equal kind "system/hook_response")
          (unless (and (equal .outcome "success") (member .exit_code '(0 nil)))
            (homun-stage-agent--note run (format "hook %s %s %s" .hook_name .outcome (or .stderr "")) 'error)))
         ((equal kind "system/permission_denied")
          (homun-stage-agent--note run (format "denied %s: %s" .tool_name .decision_reason) 'error))
         ((equal kind "system/session_title_changed") (homun-stage-agent--note run (format "title %s" .title)))
         ((equal kind "system/vcs_state_changed")
          (homun-stage-agent--note run (format "%s %s in %s" .kind .branch .cwd)))
         ((equal kind "system/code_change_published") (homun-stage-agent--note run (format "%s %s" .action .url)))
         ((equal kind "system/compact_boundary") (homun-stage-agent--note run "context compacted"))
         ((equal kind "system/api_retry")
          (homun-stage-agent--note run (format "API retry %s: %s" .attempt (or .error "")) 'warning))
         ((equal kind "broker/asked")
          (homun-stage-agent--note run (format "Permission asked: %s  %s" .tool (or .summary "")) 'warning))
         ((equal kind "broker/permission")
          (homun-stage-agent--note run (format "Permission: %s %s" .tool .decision.behavior)))
         ((equal kind "broker/exit")
          (homun-stage-agent--note run (format "■ session process exited (%s)" .code) 'error))
         ((equal kind "broker/fresh") (homun-stage-agent--note run (format "fresh session (%s)" .reason)))
         (t (homun-stage-agent--unhandled run rec kind))))))
  run)

(defun homun-stage-agent--lines (text prefix face &optional max)
  "TEXT's lines (the last MAX) behind PREFIX, in FACE."
  (let ((lines (split-string (string-trim-right text) "\n")))
    (when (and max (> (length lines) max)) (setq lines (last lines max)))
    (mapconcat (lambda (l) (propertize (concat prefix l) 'face face)) lines "\n")))

(defun homun-stage-agent--step (step results)
  "STEP as text."
  (pcase step
    (`(ask ,text) (propertize (concat "› " (car (split-string text "\n"))) 'face 'bold))
    (`(prose ,text) (propertize (concat "» " (car (split-string text "\n"))) 'face 'shadow))
    (`(think ,text) (propertize (concat "∴ " (car (split-string text "\n"))) 'face 'shadow))
    (`(note ,text ,face) (propertize (concat "  " (car (split-string text "\n"))) 'face face))
    (`(tool ,id ,name ,input)
     (let ((result (gethash id results)) (path (alist-get 'file_path input)))
       (pcase name
         ("Bash"
          (string-join
           (delq nil (list (propertize (concat "$ " (alist-get 'command input)) 'face 'bold)
                           (and (not (string-blank-p (or (car result) "")))
                                (homun-stage-agent--lines (car result) "  " 'shadow
                                                          homun-stage-agent-output-lines))
                           (and (nth 1 result) (propertize "  failed" 'face 'error))))
           "\n"))
         ((or "Edit" "MultiEdit")
          (string-join
           (cons (propertize (format "~ %s %s" name path) 'face 'bold)
                 (delq nil (list (and (alist-get 'old_string input)
                                      (homun-stage-agent--lines (alist-get 'old_string input) "  -"
                                                                'diff-removed))
                                 (and (alist-get 'new_string input)
                                      (homun-stage-agent--lines (alist-get 'new_string input) "  +"
                                                                'diff-added)))))
           "\n"))
         ("Write"
          (string-join
           (list (propertize (format "+ Write %s" path) 'face 'bold)
                 (homun-stage-agent--lines (or (alist-get 'content input) "") "  +" 'diff-added
                                           homun-stage-agent-write-lines))
           "\n"))
         (_ (propertize (format "· %s %s" name (or path (alist-get 'pattern input)
                                                    (alist-get 'command input) ""))
                        'face 'shadow)))))))

(defun homun-stage-agent--publish (id run)
  "Publish what RUN gained: the steps when a record finished one, the live block
when it grew."
  (when (plist-get run :dirty)
    (plist-put run :dirty nil)
    (let ((steps (reverse (seq-take (plist-get run :steps) homun-stage-agent-steps))))
      (homun-stage-publish
       (format "agent.%s.head" id)
       (concat (format "%s  (%d steps)" (car (split-string (or (plist-get run :brief) "") "\n"))
                       (length steps))
               (if-let* ((l (plist-get run :limits))) (format "  · %s" l) "")
               (if-let* ((n (plist-get run :unhandled)))
                   (propertize (format "  · %d unhandled" n) 'face 'warning)
                 "")))
      (homun-stage-publish
       (format "agent.%s.steps" id)
       (mapconcat (lambda (s) (homun-stage-agent--step s (plist-get run :results))) steps "\n"))))
  (let ((live (or (plist-get run :live) "")))
    (unless (equal live (plist-get run :shown))
      (plist-put run :shown live)
      (homun-stage-publish
       (format "agent.%s.live" id)
       (if (string-empty-p live) ""
         (concat "» " (substring live (max 0 (- (length live) homun-stage-agent-live-chars))) "▍"))))))

(defun homun-stage-agent--poll (id)
  "Read what the transcript of scene ID gained and publish it; non-nil while the
scene is open."
  (when-let* ((run (gethash id homun-stage-agent--runs))
              ((gethash id homun-stage-scenes)))
    (let* ((file (plist-get run :file))
           (size (and (file-readable-p file) (file-attribute-size (file-attributes file)))))
      (when size
        ;; A rotated stream starts again from its beginning
        (when (< size (plist-get run :offset)) (plist-put run :offset 0))
        (when (> size (plist-get run :offset))
          (pcase-let ((`(,records . ,offset) (homun-stage-agent--read file (plist-get run :offset))))
            (plist-put run :offset offset)
            (homun-stage-agent--fold run records)
            (homun-stage-agent--publish id run)))))
    t))

(defun homun-stage-agent-scene (id)
  "The scene tree of the agent preset for run ID."
  `((type . "col")
    (children . (((type . "text") (id . "head") (face . "title")
                  (text . ((bind . ,(format "agent.%s.head" id)))))
                 ((type . "text") (text . ""))
                 ((type . "md") (id . "steps") (text . ((bind . ,(format "agent.%s.steps" id)))))
                 ((type . "md") (id . "live") (text . ((bind . ,(format "agent.%s.live" id)))))))))

(defun homun-stage-agent--open (id title file offset period &optional log)
  "Show FILE on the Stage as scene ID, read from byte OFFSET every PERIOD seconds.
Records no branch knows are appended to LOG, by default unhandled.jsonl in
`homun-stage-dir'."
  (unless (and (gethash id homun-stage-agent--runs) (gethash id homun-stage-scenes))
    (puthash id (list :file file :offset offset :live "" :results (make-hash-table :test #'equal)
                      :log (or log (expand-file-name "unhandled.jsonl" homun-stage-dir)))
             homun-stage-agent--runs)
    (homun-stage-show "cal" id title (homun-stage-agent-scene id) "ephemeral"))
  (homun-stage-agent--poll id)
  (homun-clock-register (intern (concat "stage-agent-" id))
                        (lambda (_snap) (homun-stage-agent--poll id)) period)
  (unless noninteractive (homun-stage-display id))
  id)

;;;###autoload
(defun homun-stage-agent-open (file)
  "Show the subagent whose transcript is FILE on the Stage, live; return the scene
id."
  (homun-stage-agent--open (homun-stage-agent--id file) "Agent" file 0 homun-stage-agent-period))

(defun homun-stage-agent--start (dir turns)
  "The byte of DIR's stream.jsonl at which its last TURNS finished turns begin.
The broker's `turns' file holds where each turn ends; without it the answer is
0."
  (let ((ends (ignore-errors
                (with-temp-buffer
                  (insert-file-contents (expand-file-name "turns" dir))
                  (mapcar #'string-to-number (split-string (buffer-string) "\n" t))))))
    (or (car (last ends (1+ turns))) 0)))

;;;###autoload
(defun homun-stage-agent-open-role (role)
  "Show the headless session of ROLE on the Stage, live; return the scene id."
  (interactive "sRole: ")
  (let ((dir (expand-file-name (format "~/claude/.services/%s/stream/" role))))
    (unless (file-readable-p (expand-file-name "stream.jsonl" dir))
      (user-error "No stream of %s: it is not headless" role))
    (homun-stage-agent--open (format "session-%s" role) (capitalize role)
                             (expand-file-name "stream.jsonl" dir)
                             (homun-stage-agent--start dir homun-stage-agent-turns)
                             homun-stage-agent-live-period
                             (expand-file-name "unhandled.jsonl" dir))))

(provide 'homun-stage-agent)
;;; homun-stage-agent.el ends here
