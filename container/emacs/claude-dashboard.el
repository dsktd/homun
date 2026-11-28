;;; claude-dashboard.el --- Status, issues and questions in one buffer -*- coding: utf-8; lexical-binding: t -*-

;; An Org buffer fed by the status service and usage-db's forecast (over
;; HTTP on 127.0.0.1), the API worker ledger, the open
;; questions of `claude-question' and the open `claude-ask' buffers: a
;; heading per section, tables for lists, TODO headings for what can be
;; acted on.  It is what a new frame shows when no focus is set
;; (claude-focus.el) and `SPC o c d' brings it back. A source that cannot be read
;; shows one note in its section; nothing here signals.

(declare-function claude-bus-tell "claude-bus")
(require 'claude)
(require 'claude-focus)
(require 'homun-layout)
(require 'json)
(require 'org)
(require 'seq)
(require 'subr-x)

(defface claude-dashboard-name
  '((t :inherit font-lock-function-name-face))
  "Names and values in the dashboard, from the theme."
  :group 'claude)

(defface claude-dashboard-number
  '((t :inherit shadow))
  "Issue numbers in the dashboard, from the theme."
  :group 'claude)

(defface claude-dashboard-dim
  '((t :inherit shadow))
  "Notes and secondary text in the dashboard."
  :group 'claude)

(declare-function claude-follow-agent-count "claude-follow" (name type))
(declare-function claude-agent-show "claude-agent" (name info))

(defvar claude-ask-id)
(defvar claude-ask-timed-out)

(defvar claude-dashboard-status-url (expand-file-name "~/claude/.services/status/status.json")
  "The status service's JSON.")
(defvar claude-dashboard-forecast-url (expand-file-name "~/claude/.services/usage-db/forecast.json")
  "Usage-db's forecast JSON.")
(defvar claude-dashboard-ledger
  (expand-file-name "~/claude/.services/workers/ledger.jsonl")
  "The `claude-worker' ledger, one JSON row per run.")
(defvar claude-dashboard-questions-dir
  (or (getenv "CLAUDE_QUESTIONS_DIR") (expand-file-name "~/claude/.services/ask"))
  "The store of `claude-question': pending/<id>.json per open question.")
(defvar claude-dashboard-question-program
  (or (executable-find "claude-question") "/opt/homun/claude-question")
  "The program that records an answer (the image shim, else the mounted script).")
(defvar claude-dashboard-schedule-file
  (or (getenv "SCHEDULER_ORG") (expand-file-name "~/claude/.services/scheduler/schedule.org"))
  "The scheduler's schedule.org: a heading with a SCHEDULED stamp per next fire.")
(defvar claude-dashboard-schedule-shown 5
  "Fires listed in the Schedule section.")
(defvar claude-dashboard-issues-shown 3
  "Issues listed under each board column.")

(defvar claude-dashboard-stale 30
  "Seconds after which a fetched value counts as unreachable.")
(defvar claude-dashboard--cache (make-hash-table :test #'equal)
  "Fetched values: KEY -> (TIME . VALUE).")
(defvar claude-dashboard--processes (make-hash-table :test #'equal)
  "The running fetch of each KEY.")

(defun claude-dashboard--cached (key)
  "The value fetched for KEY, or nil when missing or older than
`claude-dashboard-stale'."
  (when-let* ((entry (gethash key claude-dashboard--cache))
              ((< (- (float-time) (car entry)) claude-dashboard-stale)))
    (cdr entry)))

(defun claude-dashboard--fetched (process _event)
  "Sentinel of PROCESS (EVENT unused): cache its parsed output, then redraw a
visible dashboard."
  (unless (process-live-p process)
    (let ((key (process-get process 'key))
          (buffer (process-buffer process)))
      (when (and (eq (process-status process) 'exit) (zerop (process-exit-status process)))
        (puthash key (cons (float-time)
                           (with-current-buffer buffer
                             (ignore-errors (funcall (process-get process 'parse)))))
                 claude-dashboard--cache))
      (kill-buffer buffer)
      (remhash key claude-dashboard--processes)
      (when-let* ((dashboard (get-buffer "*claude dashboard*"))
                  (window (get-buffer-window dashboard 'visible))
                  ((not (active-minibuffer-window))))
        (with-selected-window window (claude-dashboard--draw))))))

(defun claude-dashboard--fetch (key command parse)
  "Run COMMAND in the background for KEY unless it already runs.
PARSE reads the output buffer; its value is cached under KEY."
  (unless (process-live-p (gethash key claude-dashboard--processes))
    (ignore-errors
      (let ((process (make-process :name key :command command :noquery t
                                   :buffer (generate-new-buffer " *claude dashboard fetch*" t)
                                   :sentinel #'claude-dashboard--fetched)))
        (process-put process 'key key)
        (process-put process 'parse parse)
        (puthash key process claude-dashboard--processes)))))

(defun claude-dashboard--fetch-url (url)
  "Read the JSON file URL in the background (the services write it; their ports are
in another container)."
  (claude-dashboard--fetch url (list "cat" url)
                           (lambda () (goto-char (point-min)) (json-parse-buffer))))

(defun claude-dashboard--cancel ()
  "Kill the running fetches."
  (maphash (lambda (_key process) (delete-process process)) claude-dashboard--processes)
  (clrhash claude-dashboard--processes))

(defun claude-dashboard--dig (table &rest keys)
  "Follow KEYS through the nested hash TABLE; nil as soon as one is missing."
  (while (and keys (hash-table-p table))
    (setq table (gethash (pop keys) table)))
  (unless keys table))

(defun claude-dashboard--spend ()
  "Today's (UTC) API spend from the worker ledger, or nil without one."
  (when (file-readable-p claude-dashboard-ledger)
    (let ((today (format-time-string "%F" nil t))
          (sum 0.0))
      (with-temp-buffer
        (insert-file-contents claude-dashboard-ledger)
        (dolist (line (split-string (buffer-string) "\n" t))
          (when-let* ((row (ignore-errors (json-parse-string line)))
                      (ts (gethash "ts" row))
                      (cost (gethash "cost_usd" row)))
            (when (equal today (format-time-string "%F" (floor ts) t))
              (setq sum (+ sum cost))))))
      sum)))

;;;; Format

;; The dashboard is an Org buffer: a level-1 heading per section, tables for
;; the lists, and a TODO heading per actionable thing (issue, question).  Generated text carries the `read-only' text property; the headlines
;; of actionable items stay writable so TODO cycling and tags work, and every
;; heading carries a CLAUDE_ID property that keeps folds across redraws.

(defvar claude-dashboard-todo-keywords "TODO NEXT DOING WAIT | DONE CANCELLED"
  "The TODO sequence of the dashboard, the tracker's states with CANCELLED for
drop.")

(defun claude-dashboard--text (&rest strings)
  "Insert STRINGS as generated text, made read-only by `claude-dashboard--protect'."
  (apply #'insert strings))

(defun claude-dashboard--writable (&rest strings)
  "Insert STRINGS as text the user may change: a headline or a reply."
  (insert (propertize (apply #'concat strings) 'claude-writable t)))

(defun claude-dashboard--protect ()
  "Make all but the writable text of the buffer read-only.
Text typed right after a read-only run stays writable, so a reply can grow."
  (let ((pos (point-min))
        (inhibit-read-only t))
    (while (< pos (point-max))
      (let ((end (next-single-property-change pos 'claude-writable nil (point-max))))
        (unless (get-text-property pos 'claude-writable)
          (add-text-properties pos end '(read-only t))
          (when (< end (point-max))
            (put-text-property (1- end) end 'rear-nonsticky '(read-only))))
        (setq pos end)))))

(defun claude-dashboard--cell (value)
  "VALUE as text that is safe in an Org table cell."
  (replace-regexp-in-string "|" "¦" (format "%s" (or value "-"))))

(defun claude-dashboard--row (&rest cells)
  "Insert a read-only table row of CELLS."
  (claude-dashboard--text "| " (mapconcat #'claude-dashboard--cell cells " | ") " |\n"))

(defun claude-dashboard--rule ()
  "Insert a read-only table rule."
  (claude-dashboard--text "|-\n"))

(defun claude-dashboard--drawer (id &optional kind)
  "Insert the read-only property drawer of ID, with CLAUDE_KIND KIND when given."
  (claude-dashboard--text ":PROPERTIES:\n:CLAUDE_ID: " id "\n"
                        (if kind (format ":CLAUDE_KIND: %s\n" kind) "")
                        ":END:\n"))

(defun claude-dashboard--section (id title)
  "Insert the level-1 heading TITLE with CLAUDE_ID ID."
  (claude-dashboard--text "* " title "\n")
  (claude-dashboard--drawer id))

(defun claude-dashboard--item (id kind keyword title &optional tags)
  "Insert the actionable level-2 heading TITLE in state KEYWORD.
ID and KIND go into its drawer; TAGS, a list of strings, become Org tags.
The headline itself stays writable for `org-todo'."
  (claude-dashboard--writable
   "** " keyword " " title
   (if tags
       (concat " :" (mapconcat (lambda (tag) (replace-regexp-in-string "[^[:alnum:]_@#%]" "_" tag))
                               tags ":")
               ":")
     "")
   "\n")
  (claude-dashboard--drawer id kind))

(defun claude-dashboard--reply-heading ()
  "Insert the Reply subheading of an item, with a writable line under it."
  (claude-dashboard--text "*** Reply\n")
  (claude-dashboard--writable "\n"))

(defun claude-dashboard--note (text)
  "Insert TEXT as a read-only paragraph line."
  (claude-dashboard--text text "\n"))

(defun claude-dashboard--pct (value)
  "VALUE as a whole percentage, or a dash."
  (if (numberp value) (format "%d%%" (round value)) "-"))

;;;; Sections

(defun claude-dashboard--status (status forecast)
  "Insert the Status section from the STATUS and FORECAST tables."
  (claude-dashboard--section "status" "Status")
  (if (not forecast)
      (claude-dashboard--row "Usage" "usage-db unreachable")
    (claude-dashboard--row "Mode" (gethash "mode" forecast))
    (claude-dashboard--row "Slots" (format "%s free" (or (gethash "slots" forecast) "-")))
    (claude-dashboard--row
     "Usage" (format "5h %s  7d %s"
                     (claude-dashboard--pct (claude-dashboard--dig forecast "five_hour" "used"))
                     (claude-dashboard--pct (claude-dashboard--dig forecast "seven_day" "used")))))
  (claude-dashboard--row
   "Spend" (if-let* ((spend (claude-dashboard--spend))) (format "$%.2f today" spend) "-"))
  (if-let* ((services (and status (seq-remove (lambda (s) (equal (gethash "state" s) "disabled"))
                                               (gethash "services" status)))))
      (let ((down (seq-remove (lambda (s) (equal (gethash "state" s) "running")) services)))
        (claude-dashboard--row
         "Services"
         (format "%d of %d up%s" (- (length services) (length down)) (length services)
                 (if down (concat ", down: " (mapconcat (lambda (s) (gethash "name" s)) down " ")) ""))))
    (claude-dashboard--row "Services" "status service unreachable"))
  (claude-dashboard--text "\n"))

;; `claude-busy' prints `agent NAME (STATE)' and `worker NAME (claude-worker run)'.
(defun claude-dashboard--running ()
  "The lines of `claude-busy' fetched last: running agents and workers, or nil."
  (claude-dashboard--cached "claude-busy"))

(defvar claude-dashboard--edits-cache (cons 0 nil)
  "(TIME . ALIST) of edit counts by (NAME . TYPE); reading the follow logs is slow.")

(defvar claude-dashboard--edits-pending nil "Keys whose count an idle timer is waiting to make.")

(defvar claude-dashboard-edits-ttl 60
  "Seconds an agent's edit count is reused before the follow logs are read again.")

(defun claude-dashboard--edits (name info)
  "Edits in the follow log by the agent NAME whose INFO is `type subagent' or a
state."
  (let ((key (cons name (and info (car (split-string info))))))
    (when (> (- (float-time) (car claude-dashboard--edits-cache)) claude-dashboard-edits-ttl)
      (setq claude-dashboard--edits-cache (cons (float-time) nil)))
    (or (alist-get key (cdr claude-dashboard--edits-cache) nil nil #'equal)
        (progn (unless (member key claude-dashboard--edits-pending)
                 (push key claude-dashboard--edits-pending)
                 (run-with-idle-timer 2 nil #'claude-dashboard--count-edits key))
               0))))

(defun claude-dashboard--count-edits (key)
  "Count the edits of KEY, (NAME . TYPE), while Emacs is idle, for the next draw."
  (setq claude-dashboard--edits-pending (delete key claude-dashboard--edits-pending))
  (unless (alist-get key (cdr claude-dashboard--edits-cache) nil nil #'equal)
    (setf (alist-get key (cdr claude-dashboard--edits-cache) nil nil #'equal)
          (if (require 'claude-follow nil t)
              (claude-follow-agent-count (car key) (cdr key))
            0))))

(defun claude-dashboard--sessions (status)
  "`agent NAME (STATE)' lines for the interactive sessions in STATUS, the status
service's JSON."
  (let (lines)
    (seq-doseq (a (or (and status (gethash "agents" status)) []))
      (when (equal (gethash "kind" a) "interactive")
        (push (format "agent %s (%s)" (gethash "name" a) (gethash "status" a)) lines)))
    (nreverse lines)))

(defun claude-dashboard--agent-link (name info)
  "An Org link that opens the agent NAME with INFO in `claude-agent-show'."
  (org-link-make-string (format "claude-agent:%s::%s" name (or info "")) name))

(defvar claude-dashboard--agents-memo nil
  "(DATA . TEXT) of the last Agents section: its fetched data and the text drawn
from it.")

(defun claude-dashboard--agents-text (lines)
  "The Agents section text for the agent LINES."
  (with-temp-buffer
    (claude-dashboard--section "agents" (format "Agents (%d)" (length lines)))
    (if (not lines)
        (claude-dashboard--note "None running.")
      (claude-dashboard--row "Name" "Kind" "State" "Edits")
      (claude-dashboard--rule)
      (dolist (line lines)
        (string-match "\\`\\(\\S-+\\) \\(.*?\\)\\(?: (\\(.*\\))\\)?\\'" line)
        (let ((kind (match-string 1 line))
              (name (match-string 2 line))
              (info (match-string 3 line)))
          (claude-dashboard--row (claude-dashboard--agent-link name info) kind (or info "")
                                 (claude-dashboard--edits name info)))))
    (claude-dashboard--text "\n")
    (buffer-string)))

(defun claude-dashboard--agents (status)
  "Insert the Agents section: interactive sessions from STATUS, then what
`claude-busy' lists.
The text is drawn again only when the fetched data or an edit count changed."
  (let* ((lines (append (claude-dashboard--sessions status) (claude-dashboard--running)))
         (data (cons lines (mapcar (lambda (line)
                                     (string-match "\\`\\S-+ \\(.*?\\)\\(?: (\\(.*\\))\\)?\\'" line)
                                     (claude-dashboard--edits (match-string 1 line) (match-string 2 line)))
                                   lines))))
    (unless (equal data (car claude-dashboard--agents-memo))
      (setq claude-dashboard--agents-memo (cons data (claude-dashboard--agents-text lines))))
    (insert (cdr claude-dashboard--agents-memo))))

;; schedule.org: `* NAME :tag:' then `SCHEDULED: <2026-10-18 Sun 09:00 +1d>'.
(defun claude-dashboard--fires ()
  "The next fires as (NAME . TIME) from the schedule file, soonest first."
  (when (file-readable-p claude-dashboard-schedule-file)
    (let (fires)
      (with-temp-buffer
        (insert-file-contents claude-dashboard-schedule-file)
        (while (re-search-forward "^\\* \\(.*?\\)\\(?: +:[^ ]+:\\)?\\s-*\\(?:\n\\)SCHEDULED: <\\([^>+]*[0-9]\\)" nil t)
          (push (cons (match-string 1) (date-to-time (match-string 2))) fires)))
      (seq-take (sort (seq-filter (lambda (f) (time-less-p nil (cdr f))) fires)
                      (lambda (a b) (time-less-p (cdr a) (cdr b))))
                claude-dashboard-schedule-shown))))

(defun claude-dashboard--in (time)
  "TIME as a relative string such as \"in 2h 5m\"."
  (let* ((minutes (/ (floor (float-time (time-subtract time nil))) 60))
         (days (/ minutes 1440)) (hours (/ (% minutes 1440) 60)))
    (cond ((>= days 1) (format "in %dd %dh" days hours))
          ((>= hours 1) (format "in %dh %dm" hours (% minutes 60)))
          (t (format "in %dm" minutes)))))

(defun claude-dashboard--schedule ()
  "Insert the Schedule section."
  (when-let* ((fires (claude-dashboard--fires)))
    (claude-dashboard--section "schedule" (format "Schedule (%d)" (length fires)))
    (claude-dashboard--row "In" "Name" "At")
    (claude-dashboard--rule)
    (dolist (fire fires)
      (claude-dashboard--row (claude-dashboard--in (cdr fire)) (car fire)
                             (format-time-string "%a %H:%M" (cdr fire))))
    (claude-dashboard--text "\n")))

(defvar claude-dashboard-states '("doing" "next" "todo" "wait")
  "The tracker states listed in the Issues section, in this order.")

(defun claude-dashboard--issues (status)
  "Insert the Issues section from the STATUS table, one TODO heading per issue."
  (let ((groups (and status (gethash "issues" status))))
    (if (not (hash-table-p groups))
        (progn (claude-dashboard--section "issues" "Issues")
               (claude-dashboard--note "Status service unreachable.")
               (claude-dashboard--text "\n"))
      (claude-dashboard--section
       "issues" (format "Issues (%d open)"
                        (let ((total 0))
                          (maphash (lambda (_state issues) (setq total (+ total (length issues)))) groups)
                          total)))
      (dolist (state claude-dashboard-states)
        (seq-doseq (issue (seq-take (gethash state groups []) claude-dashboard-issues-shown))
          (claude-dashboard--item (format "issue-%s" (gethash "number" issue)) "issue"
                                  (claude-dashboard--state-of (format "issue-%s" (gethash "number" issue))
                                                              (upcase state))
                                  (format "#%s %s" (gethash "number" issue) (gethash "title" issue))
                                  (append (gethash "labels" issue) nil))
          (claude-dashboard--reply-heading)))
      (claude-dashboard--text "\n"))))

;; A question file is data from anywhere in the container: its text is shown,
;; and an answer only selects among its options or adds free text.

(defun claude-dashboard--questions ()
  "The open, unexpired questions as hash tables, oldest first."
  (let ((now (float-time)))
    (sort
     (seq-filter
      (lambda (q) (let ((expires (gethash "expires" q))) (not (and (numberp expires) (< expires now)))))
      (delq nil
            (mapcar (lambda (file)
                      (ignore-errors
                        (with-temp-buffer
                          (insert-file-contents file)
                          (json-parse-buffer))))
                    (let ((dir (expand-file-name "pending" claude-dashboard-questions-dir)))
                      (and (file-directory-p dir) (directory-files dir t "\\.json\\'"))))))
     (lambda (a b) (< (gethash "created" a 0) (gethash "created" b 0))))))

(defun claude-dashboard--insert-questions ()
  "Insert the Questions section: a TODO heading per question.
Setting it DONE answers it through `claude-dashboard-ask-question'."
  (when-let* ((questions (seq-remove (lambda (q) (claude-dashboard--state-of (format "question-%s" (gethash "id" q))))
                                      (claude-dashboard--questions))))
    (claude-dashboard--section "questions" (format "Questions (%d)" (length questions)))
    (dolist (q questions)
      (claude-dashboard--item (format "question-%s" (gethash "id" q)) "question" "TODO"
                              (replace-regexp-in-string "\n" " " (gethash "text" q)))
      (let ((note (string-trim (format "%s %s" (gethash "blocks" q "") (gethash "asker" q "")))))
        (unless (string-empty-p note)
          (claude-dashboard--note note)))
      (claude-dashboard--text "\n"))
    (claude-dashboard--text "\n")))

(defun claude-dashboard--asks ()
  "The open `claude-ask' buffers."
  (seq-filter (lambda (b)
                (with-current-buffer b
                  (and (bound-and-true-p claude-ask-id)
                       (not claude-ask-timed-out))))
              (buffer-list)))

(defun claude-dashboard--pending ()
  "Insert the Pending section: the open asks."
  (when-let* ((asks (claude-dashboard--asks)))
    (claude-dashboard--section "pending" (format "Pending (%d)" (length asks)))
    (dolist (ask asks)
      (claude-dashboard--text
       "** " (org-link-make-string (concat "claude-buffer:" (buffer-name ask)) (buffer-name ask)) "\n")
      (claude-dashboard--drawer (concat "ask-" (buffer-name ask))))
    (claude-dashboard--text "\n")))

;;;; Links

(defun claude-dashboard--follow-agent (path _arg)
  "Open the agent of PATH, `NAME::INFO', in `claude-agent-show'."
  (require 'claude-agent)
  (let ((parts (split-string path "::")))
    (claude-agent-show (car parts) (if (string-empty-p (or (cadr parts) "")) nil (cadr parts)))))

(defun claude-dashboard--follow-buffer (path _arg)
  "Show the buffer named PATH."
  (if-let* ((buffer (get-buffer path)))
      (pop-to-buffer buffer)
    (user-error "No buffer %s" path)))

(org-link-set-parameters "claude-agent" :follow #'claude-dashboard--follow-agent)
(org-link-set-parameters "claude-buffer" :follow #'claude-dashboard--follow-buffer)

;;;; Drawing

(defun claude-dashboard--render (status forecast)
  "The dashboard text for STATUS and FORECAST, with its text properties."
  (with-temp-buffer
    (claude-dashboard--text "#+TITLE: Claude dashboard\n#+TODO: " claude-dashboard-todo-keywords
                          "\n#+STARTUP: content hidedrawers\n\n")
    (claude-dashboard--status status forecast)
    (claude-dashboard--agents status)
    (claude-dashboard--schedule)
    (claude-dashboard--issues status)
    (claude-dashboard--insert-questions)
    (claude-dashboard--pending)
    (delay-mode-hooks (org-mode))
    (org-table-map-tables #'org-table-align t)
    (claude-dashboard--protect)
    (buffer-string)))

(defvar-local claude-dashboard--shown nil
  "The text drawn last, to skip redraws that change nothing.")

(defun claude-dashboard--id-at (&optional pos)
  "The CLAUDE_ID of the heading at or above POS, or nil."
  (save-excursion
    (when pos (goto-char pos))
    (when (org-back-to-heading-or-point-min t)
      (org-entry-get nil "CLAUDE_ID" t))))

(defun claude-dashboard--folded ()
  "The CLAUDE_IDs of the headings whose subtree is folded."
  (let (ids)
    (org-map-entries
     (lambda ()
       (when (and (org-fold-folded-p (line-end-position) 'outline)
                  (org-entry-get nil "CLAUDE_ID"))
         (push (org-entry-get nil "CLAUDE_ID") ids))))
    ids))

(defun claude-dashboard--goto-id (id)
  "Move to the heading with CLAUDE_ID ID; nil when there is none."
  (let ((pos (org-find-property "CLAUDE_ID" id)))
    (when pos (goto-char pos))))

(defun claude-dashboard--draw ()
  "Redraw from the fetched values, keeping point, folds and the window start."
  (let ((text (claude-dashboard--render (claude-dashboard--cached claude-dashboard-status-url)
                                        (claude-dashboard--cached claude-dashboard-forecast-url))))
    (claude-touch)
    (unless (equal-including-properties text claude-dashboard--shown)
      (let* ((first (null claude-dashboard--shown))
             (id (and (not first) (claude-dashboard--id-at)))
             (offset (and id (- (point) (save-excursion (claude-dashboard--goto-id id) (point)))))
             (folded (and (not first) (claude-dashboard--folded)))
             (kept (and (not first) (claude-dashboard--kept)))
             (top (and (eq (window-buffer) (current-buffer))
                       (count-lines (point-min) (window-start))))
             (inhibit-read-only t))
        (setq claude-dashboard--shown text)
        (erase-buffer)
        (insert text)
        (claude-dashboard--restore kept)
        (org-set-regexps-and-options)
        ;; Links shrink to their description once fontified, so align again
        (font-lock-ensure)
        (org-table-map-tables #'org-table-align t)
        (claude-dashboard--protect)
        (set-buffer-modified-p nil)
        (org-fold-show-all)
        (org-fold-hide-drawer-all)
        (save-excursion
          (dolist (folded-id folded)
            (when (claude-dashboard--goto-id folded-id)
              (org-fold-subtree t))))
        (goto-char (point-min))
        (when (and id (claude-dashboard--goto-id id))
          (forward-char (min offset (- (point-max) (point)))))
        (when top
          (save-excursion
            (goto-char (point-min))
            (forward-line top)
            (homun-layout-point (selected-window) nil (point))))))))

;; This container has no claude-busy: the Manager writes its lines to busy.txt (stale = unknown = nil)
(defun claude-dashboard--busy-lines ()
  "The agent and worker lines of the Manager's busy.txt, or nil when missing or
over 2 min old."
  (let* ((file (expand-file-name "~/claude/.services/manager/busy.txt"))
         (mtime (file-attribute-modification-time (file-attributes file))))
    (when (and mtime (< (float-time (time-since mtime)) 120))
      (with-temp-buffer
        (insert-file-contents file)
        (seq-filter (lambda (line) (string-match-p "\\`\\(agent\\|worker\\) " line))
                    (split-string (buffer-string) "\n" t))))))

(defun claude-dashboard-refresh ()
  "Fetch everything again in the background and redraw what is known."
  (interactive)
  (claude-dashboard--fetch-url claude-dashboard-status-url)
  (claude-dashboard--fetch-url claude-dashboard-forecast-url)
  (puthash "claude-busy" (cons (float-time) (claude-dashboard--busy-lines)) claude-dashboard--cache)
  (claude-dashboard--draw))

(defvar claude-dashboard-live-interval 5
  "Seconds between the automatic refreshes of a visible dashboard.")
(defvar claude-dashboard--timer nil)

(defun claude-dashboard--tick ()
  "Refresh the dashboard in its window; stop the timer when none shows it."
  (let ((window (and-let* ((buffer (get-buffer "*claude dashboard*")))
                  (get-buffer-window buffer 'visible))))
    (if (not window)
        (progn (cancel-timer claude-dashboard--timer)
               (setq claude-dashboard--timer nil))
      (unless (active-minibuffer-window)
        (with-selected-window window (claude-dashboard-refresh))))))

;;;; Talk-back

;; The user answers on the dashboard itself.  A TODO state change on an issue calls
;; `tracker state' directly; on a question DONE asks it in the minibuffer
;; (`claude-dashboard-ask-question'); any other
;; change, and C-c C-SPC s with a Reply on an item that is not a question, appends a
;; `dashboard' event to the scheduler events, which reach the manager like an alarm.

(defvar org-state)

(defvar claude-dashboard-events
  (or (getenv "CLAUDE_EVENTS") (expand-file-name "~/claude/.services/scheduler/events"))
  "The scheduler's event queue that the manager follows.")
(defvar claude-dashboard-tracker-program "tracker"
  "The tracker CLI that a state change on an issue calls.")
(defvar claude-dashboard-held 180
  "Seconds a state the user set is shown before the sources have caught up.")

(defvar claude-dashboard--states nil
  "States the user set, as (ID STATE . TIME); a question with any state is hidden.")

(defun claude-dashboard--state-of (id &optional default)
  "The state the user set on ID within `claude-dashboard-held' seconds, else
DEFAULT."
  (if-let* ((held (assoc id claude-dashboard--states))
            ((< (- (float-time) (cddr held)) claude-dashboard-held)))
      (cadr held)
    default))

(defun claude-dashboard--hold (id state)
  "Remember that the user set ID to STATE."
  (setq claude-dashboard--states
        (cons (cons id (cons state (float-time)))
              (seq-remove (lambda (held) (equal (car held) id)) claude-dashboard--states))))

(defun claude-dashboard--run (what command)
  "Run COMMAND in the background; report WHAT when it fails."
  (make-process
   :name "claude-dashboard-send" :command command :noquery t
   :buffer (generate-new-buffer " *claude dashboard send*" t)
   :sentinel (lambda (process _event)
               (unless (process-live-p process)
                 (let ((buffer (process-buffer process)))
                   (if (zerop (process-exit-status process))
                       (message "Sent %s" what)
                     (message "Sending %s failed: %s" what
                              (string-trim (with-current-buffer buffer (buffer-string)))))
                   (kill-buffer buffer))))))

(defun claude-dashboard--tell (text)
  "Send TEXT to the manager as a `dashboard' alarm: on the bus, else the scheduler
events."
  (require 'claude-bus)
  (claude-bus-tell 'manager "dashboard" text claude-dashboard-events)
  (message "Told %s: %s" claude-agent-name (truncate-string-to-width text 60 nil nil t)))

(defun claude-dashboard--reply-bounds ()
  "The (BEGIN . END) of the Reply text of the item at point, or nil."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (org-end-of-subtree t t) (point))))
      (when (re-search-forward "^\\*+ Reply[ \t]*$" end t)
        (cons (min end (1+ (point))) end)))))

(defun claude-dashboard--reply ()
  "The Reply text of the item at point, trimmed."
  (if-let* ((bounds (claude-dashboard--reply-bounds)))
      (string-trim (buffer-substring-no-properties (car bounds) (cdr bounds)))
    ""))

(defun claude-dashboard--kept ()
  "What the user wrote, as (ID REPLY) per item with a reply."
  (let (kept)
    (org-map-entries
     (lambda ()
       (when (org-entry-get nil "CLAUDE_KIND")
         (let ((reply (claude-dashboard--reply)))
           (unless (string-empty-p reply)
             (push (list (org-entry-get nil "CLAUDE_ID") reply) kept))))))
    kept))

(defun claude-dashboard--restore (kept)
  "Put back what the user wrote, KEPT from `claude-dashboard--kept'."
  (save-excursion
    (dolist (item kept)
      (when (claude-dashboard--goto-id (car item))
        (when-let* ((bounds (claude-dashboard--reply-bounds))
                    ((not (string-empty-p (nth 1 item)))))
          (goto-char (car bounds))
          (insert (propertize (concat (nth 1 item) "\n") 'claude-writable t)))))))

(defun claude-dashboard--item-at ()
  "The (ID KIND TITLE) of the actionable item at or above point, or nil."
  (save-excursion
    (when (org-back-to-heading-or-point-min t)
      (while (and (not (org-entry-get nil "CLAUDE_KIND")) (org-up-heading-safe)))
      (when-let* ((kind (org-entry-get nil "CLAUDE_KIND")))
        (list (org-entry-get nil "CLAUDE_ID") kind (org-get-heading t t t t))))))

(defun claude-dashboard--answer (id)
  "Answer the pending question ID through `claude-dashboard-ask-question'."
  (unwind-protect
      (if-let* ((question (seq-find (lambda (q) (equal (gethash "id" q) id))
                                    (claude-dashboard--questions))))
          (claude-dashboard-ask-question question)
        (user-error "Question %s is gone" id))
    (setq claude-dashboard--shown nil)
    (claude-dashboard--draw)))

;;;###autoload
(defun claude-dashboard-ask-question (question)
  "Answer QUESTION (a hash table) in the minibuffer: options, then free text.
One option is chosen as in `claude-pick', several with
`completing-read-multiple'; the text is read as in `claude-ask'.  Empty text is
allowed."
  (let* ((options (append (gethash "options" question) nil))
         (multiple (eq (gethash "multiple" question) t))
         (prompt (format "%s " (replace-regexp-in-string "\n" " " (gethash "text" question ""))))
         (choices (cond ((null options) nil)
                        (multiple (completing-read-multiple prompt options nil t))
                        (t (list (completing-read prompt options nil t)))))
         (text (string-trim (read-string "Reply (optional): "))))
    (claude-dashboard--run
     (concat "answer to " (gethash "id" question))
     (append (list claude-dashboard-question-program "answer" (gethash "id" question) "--text" text)
             (mapcan (lambda (choice) (list "--choice" choice)) choices)))))

(defun claude-dashboard--changed ()
  "Act on a TODO state change the user made, for
`org-after-todo-state-change-hook'."
  (when-let* ((item (claude-dashboard--item-at))
              (id (nth 0 item))
              (state (or org-state "")))
    (cond ((equal (nth 1 item) "issue")
           (let ((number (string-remove-prefix "issue-" id)))
             (claude-dashboard--hold id state)
             (claude-dashboard--run
              (format "#%s %s" number state)
              (list claude-dashboard-tracker-program "state" number
                    (if (equal state "CANCELLED") "drop" (downcase state))))))
          ((and (equal (nth 1 item) "question") (equal state "DONE"))
           (claude-dashboard--answer (string-remove-prefix "question-" id)))
          (t
           (claude-dashboard--hold id state)
           (claude-dashboard--tell (format "dashboard: %s %s set to %s: %s%s"
                                           (nth 1 item) id state (nth 2 item)
                                           (let ((reply (claude-dashboard--reply)))
                                             (if (string-empty-p reply) "" (concat "\nReply: " reply)))))))))

(defun claude-dashboard-send ()
  "Send the Reply of the item at point: answer a question, else tell the manager."
  (interactive)
  (let ((item (claude-dashboard--item-at)))
    (unless item (user-error "No item at point"))
    (unless (claude-confirm (format "Send the reply on %s? " (nth 0 item))) (user-error "Not sent"))
    (cond ((equal (nth 1 item) "question")
           (claude-dashboard--answer (string-remove-prefix "question-" (nth 0 item))))
          ((string-empty-p (claude-dashboard--reply)) (user-error "Write a reply under Reply first"))
          (t
           (claude-dashboard--tell (format "dashboard: reply on %s %s: %s\nReply: %s"
                                           (nth 1 item) (nth 0 item) (nth 2 item)
                                           (claude-dashboard--reply)))
           (let ((bounds (claude-dashboard--reply-bounds)))
             (delete-region (car bounds) (cdr bounds)))))
    (setq claude-dashboard--shown nil)
    (claude-dashboard--draw)))

;;;; User Interface

(defvar claude-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-SPC g") #'claude-dashboard-refresh)
    (define-key map (kbd "C-c C-SPC s") #'claude-dashboard-send)
    map)
  "Keys of `claude-dashboard-mode', on top of Org's.")

(define-minor-mode claude-dashboard-mode
  "The Claude dashboard: an Org buffer redrawn from the status sources.
C-c C-t (or S-<left>/S-<right>) on an item sends its new state, C-c C-SPC s
sends the text under its Reply heading, C-c g refreshes and TAB folds."
  :lighter " Dash" :keymap claude-dashboard-mode-map
  (when claude-dashboard-mode
    (setq-local org-log-done nil
                org-todo-log-states nil
                org-startup-folded nil)
    (setq header-line-format
          (claude-header "Dashboard" "C-c C-t state | C-c C-SPC s send (asks) | gr refresh | TAB fold"))
    (claude-org-modern)
    (add-hook 'org-after-todo-state-change-hook #'claude-dashboard--changed nil t)
    (add-hook 'kill-buffer-hook #'claude-dashboard--cancel nil t)))

(declare-function evil-define-key* "evil-core")
(with-eval-after-load 'evil
  (evil-define-key* '(normal motion) claude-dashboard-mode-map
    (kbd "gr") #'claude-dashboard-refresh))

;; The timer runs with another buffer current
(defun claude-dashboard--refresh-buffer (buffer)
  "Refresh BUFFER, the dashboard, if it is still there."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer (claude-dashboard-refresh))))

;;;###autoload
(defun claude-dashboard-buffer ()
  "The dashboard buffer, freshly drawn, kept live while a window shows it."
  (let ((buffer (get-buffer-create "*claude dashboard*")))
    (with-current-buffer buffer
      (unless claude-dashboard-mode
        (org-mode)
        (claude-dashboard-mode 1))
      ;; The fetches take a third of a second: show what the buffer has (or a
      ;; placeholder) now and draw it fresh a moment later
      (cond (noninteractive (claude-dashboard-refresh))
            (t (when (= (buffer-size) 0)
                 (let ((inhibit-read-only t)) (insert "Loading the dashboard...\n")))
               (run-with-timer 0 nil #'claude-dashboard--refresh-buffer buffer))))
    (unless (or noninteractive claude-dashboard--timer)
      (setq claude-dashboard--timer
            (run-with-timer claude-dashboard-live-interval claude-dashboard-live-interval
                            #'claude-dashboard--tick)))
    buffer))

;;;###autoload
(defun claude-dashboard ()
  "Show the dashboard buffer, freshly drawn."
  (interactive)
  (let ((buffer (claude-dashboard-buffer)))
    (if noninteractive (set-buffer buffer) (switch-to-buffer buffer))
    buffer))

(defun claude-dashboard-initial-buffer ()
  "For `initial-buffer-choice': the focus, or the dashboard when there is none."
  (claude-focus-show-here)
  (current-buffer))

;;;###autoload
(defun claude-frame-start ()
  "What `homun emacs' without a file shows in the frame it just made.
The focus when one is set, else the cockpit layout (`homun-layout-apply')."
  (if (or noninteractive (claude-focus--current))
      (claude-focus-show-here)
    (homun-layout-apply)))

(provide 'claude-dashboard)

;;; claude-dashboard.el ends here
