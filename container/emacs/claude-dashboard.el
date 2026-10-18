;;; claude-dashboard.el --- Status, issues and queue in one buffer -*- lexical-binding: t -*-

;; A `magit-section' buffer fed by the status service and usage-db's forecast
;; (over HTTP on 127.0.0.1), the API worker ledger, the queue files and the
;; open `claude-ask' buffers. It is the first thing a fresh daemon's first
;; frame shows and `SPC c d' brings it back. A source that cannot be read
;; shows one note in its section; nothing here signals.

(require 'json)
(require 'magit-section)
(require 'seq)
(require 'subr-x)
(require 'url)

(defvar claude-queue-memory-dir)
(declare-function claude-open-dir "claude" (dir))
(defvar claude-ask-id)
(defvar claude-ask-timed-out)

(defvar claude-dashboard-status-url "http://127.0.0.1:8421/status.json"
  "The status service's JSON.")
(defvar claude-dashboard-forecast-url "http://127.0.0.1:8420/forecast.json"
  "Usage-db's forecast JSON.")
(defvar claude-dashboard-ledger
  (expand-file-name "~/claude/.services/workers/ledger.jsonl")
  "The `claude-worker' ledger, one JSON row per run.")
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

(defun claude-dashboard--line (label value)
  "Insert a LABEL: VALUE line."
  (insert "  " (propertize (format "%-10s" label) 'face 'font-lock-keyword-face)
          (format "%s\n" value)))

(defun claude-dashboard--note (what)
  "Insert the one-line note that WHAT is unreachable."
  (insert (propertize (format "  %s unreachable\n" what) 'face 'shadow)))

(defun claude-dashboard--pct (value)
  "VALUE as a whole percentage, or a dash."
  (if (numberp value) (format "%d%%" (round value)) "-"))

(defun claude-dashboard--status (status forecast)
  "Insert the Status section from the STATUS and FORECAST tables."
  (magit-insert-section (claude-status)
    (magit-insert-heading "Status")
    (if (not forecast)
        (claude-dashboard--note "usage-db")
      (claude-dashboard--line "mode" (or (gethash "mode" forecast) "-"))
      (claude-dashboard--line "slots" (format "%s free" (or (gethash "slots" forecast) "-")))
      (claude-dashboard--line
       "usage" (format "5h %s used, 7d %s used"
                       (claude-dashboard--pct (claude-dashboard--dig forecast "five_hour" "used"))
                       (claude-dashboard--pct (claude-dashboard--dig forecast "seven_day" "used")))))
    (claude-dashboard--line
     "API spend" (if-let* ((spend (claude-dashboard--spend))) (format "$%.2f today" spend) "-"))
    (if-let* ((services (and status (gethash "services" status))))
        (let ((down (seq-remove (lambda (s) (equal (gethash "state" s) "running")) services)))
          (claude-dashboard--line
           "services" (format "%d of %d up%s" (- (length services) (length down)) (length services)
                              (if down (concat ", down: " (mapconcat (lambda (s) (gethash "name" s)) down " ")) ""))))
      (claude-dashboard--note "status service"))))

(defun claude-dashboard--issues (status)
  "Insert the Open issues section from the STATUS table."
  (let ((groups (and status (gethash "issues" status))))
    (magit-insert-section (claude-issues)
      (magit-insert-heading "Open issues")
      (if (not (hash-table-p groups))
          (claude-dashboard--note "issues")
        (maphash
         (lambda (state issues)
           (magit-insert-section (claude-state state)
             (magit-insert-heading (format "  %s (%d)" state (length issues)))
             (seq-doseq (issue (seq-take issues claude-dashboard-issues-shown))
               (magit-insert-section (claude-issue (gethash "url" issue))
                 (insert (format "    #%d %s\n" (gethash "number" issue) (gethash "title" issue)))))))
         groups)))))

(defun claude-dashboard--queue-items ()
  "The descriptions of the queued items, from the front matter of queue-*.md."
  (when (file-directory-p claude-queue-memory-dir)
    (mapcar (lambda (file)
              (with-temp-buffer
                (insert-file-contents file nil 0 2000)
                (if (re-search-forward "^description: \\(.*\\)$" nil t)
                    (match-string 1)
                  (file-name-base file))))
            (directory-files claude-queue-memory-dir t "\\`queue-.*\\.md\\'"))))

(defun claude-dashboard--pending ()
  "Insert the Queue and pending section."
  (let ((items (claude-dashboard--queue-items))
        (asks (seq-filter (lambda (b)
                            (with-current-buffer b
                              (and (bound-and-true-p claude-ask-id)
                                   (not claude-ask-timed-out))))
                          (buffer-list))))
    (magit-insert-section (claude-pending)
      (magit-insert-heading "Queue and pending")
      (dolist (item items)
        (insert (format "  queued    %s\n" item)))
      (dolist (ask asks)
        (magit-insert-section (claude-ask ask)
          (insert (format "  question  %s\n" (buffer-name ask)))))
      (unless (or items asks)
        (insert (propertize "  nothing\n" 'face 'shadow))))))

(defun claude-dashboard-visit ()
  "Open the issue or question at point, or toggle the section."
  (interactive)
  (when-let* ((section (magit-current-section)))
    (pcase (oref section type)
      ('claude-issue (browse-url (oref section value)))
      ('claude-ask (pop-to-buffer (oref section value)))
      (_ (magit-section-toggle section)))))

(defvar claude-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "g") #'claude-dashboard-refresh)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "RET") #'claude-dashboard-visit)
    map))

(define-derived-mode claude-dashboard-mode magit-section-mode "Claude-Dash"
  "Status, open issues and the queue; TAB folds, g refreshes, q buries.")

;; evil keeps this mode in motion state, where its own TAB, g and RET win
(declare-function evil-define-key "evil-core")
(with-eval-after-load 'evil
  (evil-define-key '(normal motion) claude-dashboard-mode-map
    (kbd "g") #'claude-dashboard-refresh
    (kbd "q") #'quit-window
    (kbd "RET") #'claude-dashboard-visit
    (kbd "TAB") #'magit-section-toggle
    (kbd "<tab>") #'magit-section-toggle))

(defun claude-dashboard-refresh ()
  "Fetch everything again and redraw."
  (interactive)
  (let ((status (claude-dashboard--get claude-dashboard-status-url))
        (forecast (claude-dashboard--get claude-dashboard-forecast-url))
        (line (line-number-at-pos))
        (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (claude-dashboard)
      (claude-dashboard--status status forecast)
      (insert "\n")
      (claude-dashboard--issues status)
      (insert "\n")
      (claude-dashboard--pending))
    (goto-char (point-min))
    (forward-line (1- line))))

;;;###autoload
(defun claude-dashboard ()
  "Show the dashboard buffer, freshly drawn."
  (interactive)
  (let ((buffer (get-buffer-create "*claude dashboard*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'claude-dashboard-mode)
        (claude-dashboard-mode))
      (claude-dashboard-refresh))
    (if noninteractive (set-buffer buffer) (switch-to-buffer buffer))
    buffer))

(defvar claude-dashboard--first-frame t
  "Non-nil until the dashboard was handed to a client frame.")

(defun claude-dashboard-initial-buffer ()
  "For `initial-buffer-choice': the dashboard once, then the scratch buffer."
  (if (prog1 claude-dashboard--first-frame
        (setq claude-dashboard--first-frame nil))
      (claude-dashboard)
    (get-scratch-buffer-create)))

;;;###autoload
(defun claude-frame-start (dir)
  "What `c emacs' without a file shows in the frame it just made.
The dashboard for the first such frame, then DIR (`claude-open-dir')."
  (if (prog1 claude-dashboard--first-frame
        (setq claude-dashboard--first-frame nil))
      (claude-dashboard)
    (claude-open-dir dir)))

(provide 'claude-dashboard)

;;; claude-dashboard.el ends here
