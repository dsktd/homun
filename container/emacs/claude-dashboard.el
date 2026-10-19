;;; claude-dashboard.el --- Status, issues and queue in one buffer -*- lexical-binding: t -*-

;; A `magit-section' buffer fed by the status service and usage-db's forecast
;; (over HTTP on 127.0.0.1), the API worker ledger, the queue files, the
;; open questions of `claude-question' and the open `claude-ask' buffers. It is what a new frame shows when no focus is set
;; (claude-focus.el) and `SPC c d' brings it back. A source that cannot be read
;; shows one note in its section; nothing here signals.

(require 'claude-focus)
(require 'cl-lib)
(require 'json)
(require 'magit-section)
(require 'seq)
(require 'subr-x)
(require 'transient)
(require 'url)
(require 'claude-answer)

(defface claude-dashboard-name
  '((((background light)) :foreground "SkyBlue4") (t :foreground "LightSkyBlue1"))
  "Names and values in the dashboard, coloured like magit's local branch."
  :group 'claude)

(defface claude-dashboard-number
  '((((background light)) :foreground "grey40") (t :foreground "grey60"))
  "Issue numbers in the dashboard, like magit's hashes."
  :group 'claude)

(defface claude-dashboard-dim
  '((t :inherit shadow))
  "Notes and secondary text in the dashboard."
  :group 'claude)

(defvar claude-queue-memory-dir)
(defvar claude-ask-id)
(defvar claude-ask-timed-out)

(defvar claude-dashboard-status-url "http://127.0.0.1:8421/status.json"
  "The status service's JSON.")
(defvar claude-dashboard-forecast-url "http://127.0.0.1:8420/forecast.json"
  "Usage-db's forecast JSON.")
(defvar claude-dashboard-ledger
  (expand-file-name "~/claude/.services/workers/ledger.jsonl")
  "The `claude-worker' ledger, one JSON row per run.")
(defvar claude-dashboard-questions-dir
  (or (getenv "CLAUDE_QUESTIONS_DIR") (expand-file-name "~/claude/.services/ask"))
  "The store of `claude-question': pending/<id>.json per open question.")
(defvar claude-dashboard-question-program
  (or (executable-find "claude-question") "/opt/claude-wrapper/claude-question")
  "The program that records an answer (the image shim, else the mounted script).")
(defvar claude-dashboard-schedule-file
  (or (getenv "SCHEDULER_ORG") (expand-file-name "~/claude/.services/scheduler/schedule.org"))
  "The scheduler's schedule.org: a heading with a SCHEDULED stamp per next fire.")
(defvar claude-dashboard-schedule-shown 5
  "Fires listed in the Schedule section.")
(defvar claude-dashboard-issues-shown 3
  "Issues listed under each board column.")

(defun claude-dashboard--get (url)
  "The JSON at URL as a hash table, or nil when it cannot be fetched."
  (ignore-errors
    (when-let* ((buffer (url-retrieve-synchronously url t t 2)))
      (with-current-buffer buffer
        (unwind-protect
            (progn (goto-char (point-min))
                   (re-search-forward "\r?\n\r?\n")
                   (json-parse-buffer))
          (kill-buffer buffer))))))

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

;; The header lines and sections follow `magit-status': `Head:'-style lines
;; (label, value in a magit face), then sections whose headings carry a count.

(defun claude-dashboard--header (label value &optional face)
  "Insert a header line, like magit's `Head:', of LABEL and VALUE.
VALUE is shown in FACE when given."
  (insert (propertize (format "%-10s" (concat label ":")) 'font-lock-face 'magit-section-heading)
          (if face (propertize value 'font-lock-face face) value)
          "\n"))

(defun claude-dashboard--unreachable (label what)
  "Insert the header line LABEL saying that WHAT is unreachable."
  (claude-dashboard--header label (format "%s unreachable" what) 'claude-dashboard-dim))

(defun claude-dashboard--pct (value)
  "VALUE as a whole percentage, or a dash."
  (if (numberp value) (format "%d%%" (round value)) "-"))

(defun claude-dashboard--headers (status forecast)
  "Insert the header lines from the STATUS and FORECAST tables."
  (if (not forecast)
      (claude-dashboard--unreachable "Usage" "usage-db")
    (claude-dashboard--header "Mode" (or (gethash "mode" forecast) "-") 'claude-dashboard-name)
    (claude-dashboard--header "Slots" (format "%s free" (or (gethash "slots" forecast) "-")))
    (claude-dashboard--header
     "Usage" (format "5h %s  7d %s"
                     (claude-dashboard--pct (claude-dashboard--dig forecast "five_hour" "used"))
                     (claude-dashboard--pct (claude-dashboard--dig forecast "seven_day" "used")))))
  (claude-dashboard--header
   "Spend" (if-let* ((spend (claude-dashboard--spend))) (format "$%.2f today" spend) "-"))
  (if-let* ((services (and status (gethash "services" status))))
      (let ((down (seq-remove (lambda (s) (equal (gethash "state" s) "running")) services)))
        (claude-dashboard--header
         "Services"
         (format "%d of %d up%s" (- (length services) (length down)) (length services)
                 (if down (concat ", down: " (mapconcat (lambda (s) (gethash "name" s)) down " ")) ""))
         (if down 'error 'success)))
    (claude-dashboard--unreachable "Services" "status service")))

;; `claude-busy' prints `agent NAME (STATE)' and `worker NAME (claude-worker run)'.
(defun claude-dashboard--running ()
  "The lines of `claude-busy': running agents and workers, or nil."
  (ignore-errors
    (with-temp-buffer
      (call-process "timeout" nil '(t nil) nil "5" "claude-busy")
      (seq-filter (lambda (line) (string-match-p "\\`\\(agent\\|worker\\) " line))
                  (split-string (buffer-string) "\n" t)))))

(defun claude-dashboard--agents ()
  "Insert the Agents section."
  (let ((lines (claude-dashboard--running)))
    (magit-insert-section (claude-agents)
      (magit-insert-heading (format "Agents (%d)" (length lines)))
      (dolist (line lines)
        (string-match "\\`\\(\\S-+\\) \\(.*?\\)\\(?: (\\(.*\\))\\)?\\'" line)
        (magit-insert-section (claude-agent line)
          (insert (propertize (match-string 2 line) 'font-lock-face 'claude-dashboard-name)
                  (propertize (format "  %s %s" (match-string 1 line) (or (match-string 3 line) ""))
                              'font-lock-face 'claude-dashboard-dim)
                  "\n")))
      (unless lines
        (insert (propertize "none running\n" 'font-lock-face 'claude-dashboard-dim)))
      (insert "\n"))))

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
  (let ((fires (claude-dashboard--fires)))
    (when fires
      (magit-insert-section (claude-schedule)
        (magit-insert-heading (format "Schedule (%d)" (length fires)))
        (pcase-dolist (`(,name . ,time) fires)
          (magit-insert-section (claude-fire name)
            (insert (propertize (format "%-14s" (claude-dashboard--in time)) 'font-lock-face 'claude-dashboard-dim)
                    (propertize name 'font-lock-face 'claude-dashboard-name)
                    (propertize (format-time-string "  %a %H:%M" time) 'font-lock-face 'claude-dashboard-dim)
                    "\n")))
        (insert "\n")))))

(defun claude-dashboard--issues (status)
  "Insert the Open issues section from the STATUS table."
  (let ((groups (and status (gethash "issues" status))))
    (if (not (hash-table-p groups))
        (claude-dashboard--header "Issues" "status service unreachable" 'claude-dashboard-dim)
      (magit-insert-section (claude-issues)
        (magit-insert-heading
          (format "Open issues (%d)"
                  (let ((total 0))
                    (maphash (lambda (_state issues) (cl-incf total (length issues))) groups)
                    total)))
        (maphash
         (lambda (state issues)
           (when (> (length issues) 0)
             (magit-insert-section (claude-state state)
               (magit-insert-heading t state)
               (seq-doseq (issue (seq-take issues claude-dashboard-issues-shown))
                 (magit-insert-section (claude-issue (gethash "url" issue))
                   (insert (propertize (format "#%-4d" (gethash "number" issue)) 'font-lock-face 'claude-dashboard-number)
                           (gethash "title" issue) "\n"))))))
         groups)
        (insert "\n")))))

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
  "Insert the Questions section."
  (let ((questions (claude-dashboard--questions)))
    (when questions
      (magit-insert-section (claude-questions)
        (magit-insert-heading (format "Questions (%d)" (length questions)))
        (dolist (q questions)
          (magit-insert-section (claude-question q t)
            (magit-insert-heading
              (gethash "text" q)
              (propertize (format "  %s %s" (gethash "blocks" q "") (gethash "asker" q ""))
                          'font-lock-face 'claude-dashboard-dim))
            (dolist (option (append (gethash "options" q) nil))
              (insert (propertize (format "  - %s\n" option) 'font-lock-face 'claude-dashboard-dim)))
            (when (or (eq (gethash "free_text" q) t) (zerop (length (gethash "options" q))))
              (insert (propertize "  (free-text reply)\n" 'font-lock-face 'claude-dashboard-dim)))))
        (insert "\n")))))

(defun claude-dashboard--queue-items ()
  "The queued items as (FILE . DESCRIPTION), from the front matter of queue-*.md."
  (when (file-directory-p claude-queue-memory-dir)
    (mapcar (lambda (file)
              (cons file
                    (with-temp-buffer
                      (insert-file-contents file nil 0 2000)
                      (if (re-search-forward "^description: \\(.*\\)$" nil t)
                          (match-string 1)
                        (file-name-base file)))))
            (directory-files claude-queue-memory-dir t "\\`queue-.*\\.md\\'"))))

(defun claude-dashboard--pending ()
  "Insert the Queue and pending section."
  (let ((items (claude-dashboard--queue-items))
        (asks (seq-filter (lambda (b)
                            (with-current-buffer b
                              (and (bound-and-true-p claude-ask-id)
                                   (not claude-ask-timed-out))))
                          (buffer-list))))
    (when (or items asks)
      (magit-insert-section (claude-pending)
        (magit-insert-heading (format "Queue and pending (%d)" (+ (length items) (length asks))))
        (when items
          (magit-insert-section (claude-queued)
            (magit-insert-heading t "Queued")
            (pcase-dolist (`(,file . ,description) items)
              (magit-insert-section (claude-queue-item file)
                (insert description "\n")))))
        (when asks
          (magit-insert-section (claude-asks)
            (magit-insert-heading t "Questions")
            (dolist (ask asks)
              (magit-insert-section (claude-ask ask)
                (insert (buffer-name ask) "\n")))))
        (insert "\n")))))

(defun claude-dashboard-visit ()
  "Visit the issue, queue item or question at point, or toggle the section."
  (interactive)
  (when-let* ((section (magit-current-section)))
    (pcase (oref section type)
      ('claude-issue (browse-url (oref section value)))
      ('claude-queue-item (find-file (oref section value)))
      ('claude-ask (pop-to-buffer (oref section value)))
      ('claude-question (claude-answer-open (oref section value)))
      (_ (magit-section-toggle section)))))

(defun claude-dashboard-refresh ()
  "Fetch everything again and redraw, keeping point and folds."
  (interactive)
  (let* ((status (claude-dashboard--get claude-dashboard-status-url))
         (forecast (claude-dashboard--get claude-dashboard-forecast-url))
         (section (magit-current-section))
         (position (and section (magit-section-get-relative-position section)))
         (top (and (eq (window-buffer) (current-buffer))
                   (line-number-at-pos (window-start))))
         (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (claude-dashboard)
      (claude-dashboard--headers status forecast)
      (insert "\n")
      (claude-dashboard--agents)
      (claude-dashboard--schedule)
      (claude-dashboard--issues status)
      (claude-dashboard--insert-questions)
      (claude-dashboard--pending))
    (goto-char (point-min))
    (when section
      (apply #'magit-section-goto-successor section position))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (when top
      (save-excursion
        (goto-char (point-min))
        (forward-line (1- top))
        (set-window-start nil (point))))
    (magit-section-update-highlight)))

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

(transient-define-prefix claude-dashboard-dispatch ()
  "Keys of the Claude dashboard."
  ["Dashboard"
   ("g" "Refresh" claude-dashboard-refresh)
   ("RET" "Visit thing at point" claude-dashboard-visit)
   ("q" "Quit" quit-window)])

(defvar claude-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "g") #'claude-dashboard-refresh)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "RET") #'claude-dashboard-visit)
    (define-key map (kbd "?") #'claude-dashboard-dispatch)
    map))

(define-derived-mode claude-dashboard-mode magit-section-mode "Claude-Dash"
  "Status, open issues and the queue, as `magit-status' shows a repository.")

;; Like evil-collection-magit: gr refreshes (g is evil's prefix), TAB, RET, q, ?
(declare-function evil-define-key "evil-core")
(with-eval-after-load 'evil
  (evil-define-key '(normal motion) claude-dashboard-mode-map
    (kbd "gr") #'claude-dashboard-refresh
    (kbd "q") #'quit-window
    (kbd "RET") #'claude-dashboard-visit
    (kbd "TAB") #'magit-section-toggle
    (kbd "<tab>") #'magit-section-toggle
    (kbd "?") #'claude-dashboard-dispatch))

;;;###autoload
(defun claude-dashboard-buffer ()
  "The dashboard buffer, freshly drawn, kept live while a window shows it."
  (let ((buffer (get-buffer-create "*claude dashboard*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'claude-dashboard-mode)
        (claude-dashboard-mode))
      (claude-dashboard-refresh))
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
  "What `c emacs' without a file shows in the frame it just made.
The focus when one is set, else the dashboard."
  (claude-focus-show-here))

(provide 'claude-dashboard)

;;; claude-dashboard.el ends here
