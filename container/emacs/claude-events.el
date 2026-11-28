;;; claude-events.el --- Event log of the Manager's Claude Code session -*- coding: utf-8; lexical-binding: t -*-

;; `*claude-events*' lists what happened in the main session, newest first: the hook events
;; that container/event-hook.sh appends to ~/claude/.services/events/log.jsonl (watched with
;; file-notify), plus what no hook reports, read from the tail of the session transcript:
;; API errors (assistant entries with isApiErrorMessage, e.g. rate_limit "resets 9:40pm") and
;; MCP servers added or removed (mcp_instructions_delta attachments).  Retries and rate-limit
;; waits are not written anywhere; the error entry that ends a turn is all there is.
;;
;; Keys: n notifications, e errors, s session, t tools toggle a filter (all shown by default),
;; g re-reads the log, q buries.  Toasts (echo area, and a ● after the Homun row of the board
;; until the buffer is viewed) for errors, rate-limit errors, MCP removals, Notification events
;; and a stall: busy with no new event for `claude-events-stall-seconds'.  While a rate limit
;; reset is ahead, `global-mode-string' shows "rate-limited until HH:MM".
;; Alarms to Cal come from the bus (bus/user/inbox.jsonl, `claude-bus') as `Alarm' notifications.

(require 'cl-lib)
(require 'filenotify)
(require 'json)
(require 'subr-x)

(defvar claude-events-dir (expand-file-name "~/claude/.services/events/"))
(defvar claude-events-transcript-dir (expand-file-name
                                           (concat "~/.claude/projects/"
                                                   (replace-regexp-in-string "/" "-" (expand-file-name "~/claude"))
                                                   "/")))
(defvar claude-events-stall-seconds 60)
(defvar claude-events-max 500 "Items kept, newest first.")
(defconst claude-events-buffer-name "*claude-events*")

(defvar claude-events--items nil "Newest first: plists :ts :event :session :kind :summary :class.")
(defvar claude-events--log-pos 0 "Bytes of log.jsonl already read.")
(defvar claude-events--tx-file nil)
(defvar claude-events--tx-pos nil "Bytes of the transcript already read; nil before the first look.")
(defvar claude-events--filters '(n e s t) "Classes shown.")
(defvar claude-events--unread nil "A toast has not been seen in the events buffer yet.")
(defvar claude-events--rate-until nil "Epoch seconds a rate limit lasts until, or nil.")
(defvar claude-events--stall-for nil "Timestamp of the last event a stall toast was shown for.")
(defvar claude-events--watch nil)
(defvar claude-events--timer nil)
(defvar claude-events--mode-string '(:eval (claude-events-mode-line)))

(declare-function homun-key-hint "claude")

(defun claude-events--class (event)
  "The filter class of EVENT: n notification, e error, t tool, s everything else."
  (cond ((member event '("Notification" "Alarm")) 'n)
        ((member event '("StopFailure" "PostToolUseFailure" "ApiError")) 'e)
        ((member event '("PreToolUse" "PostToolUse" "PermissionRequest")) 't)
        (t 's)))

(defun claude-events--item (ts event session kind summary)
  (list :ts ts :event event :session session :kind kind :summary summary
        :class (claude-events--class event)))

(defun claude-events--read-json (line)
  (ignore-errors (json-parse-string line :object-type 'alist :null-object nil)))

(defun claude-events-parse-hook-line (line)
  "The item of one log.jsonl LINE, or nil."
  (when-let* ((o (claude-events--read-json line))
              (ev (alist-get 'event o)))
    (claude-events--item (alist-get 'ts o) ev (alist-get 'session o)
                         (or (alist-get 'kind o) "") (or (alist-get 'summary o) ""))))

(defun claude-events--iso-time (string)
  (and (stringp string) (ignore-errors (float-time (date-to-time string)))))

(defun claude-events-parse-transcript-line (line)
  "The items of one transcript LINE: an API error or MCP servers added or removed."
  (when (or (string-search "\"isApiErrorMessage\":true" line)
            (string-search "\"mcp_instructions_delta\"" line))
    (when-let* ((o (claude-events--read-json line))
                (ts (or (claude-events--iso-time (alist-get 'timestamp o)) (float-time))))
      (let ((att (alist-get 'attachment o)))
        (cond
         ((eq (alist-get 'isApiErrorMessage o) t)
          (let ((text (or (ignore-errors (alist-get 'text (aref (alist-get 'content (alist-get 'message o)) 0))) "")))
            (list (claude-events--item ts "ApiError" (alist-get 'sessionId o)
                                       (or (alist-get 'error o) "error")
                                       (truncate-string-to-width text 120)))))
         ((equal (alist-get 'type att) "mcp_instructions_delta")
          (append (mapcar (lambda (n) (claude-events--item ts "McpAdded" (alist-get 'sessionId o) "mcp" n))
                          (alist-get 'addedNames att))
                  (mapcar (lambda (n) (claude-events--item ts "McpRemoved" (alist-get 'sessionId o) "mcp" n))
                          (alist-get 'removedNames att)))))))))

(defun claude-events--reset-time (text &optional now)
  "Epoch seconds of the next \"resets 9:40pm\" clock time in TEXT after NOW, or nil."
  (when (string-match "resets \\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?\\s-*\\([ap]m\\)" text)
    (let* ((now (or now (float-time)))
           (h (mod (string-to-number (match-string 1 text)) 12))
           (m (string-to-number (or (match-string 2 text) "0")))
           (h (+ h (if (equal (match-string 3 text) "pm") 12 0)))
           (d (decode-time now))
           (at (float-time (encode-time (list 0 m h (decoded-time-day d) (decoded-time-month d)
                                              (decoded-time-year d) nil -1 (decoded-time-zone d))))))
      (if (> at now) at (+ at 86400)))))

(defconst claude-events-mcp-grace 60
  "Seconds an MCP server has to stay removed before that is announced.")

(defconst claude-events-toast-quiet 30
  "Seconds in which the same event and summary are announced once.")

(defvar claude-events--mcp-removed nil
  "Alist of (SERVER . TS): MCP servers removed and not added again, not yet
announced.")

(defvar claude-events--toasted nil
  "Alist of (TEXT . TS): the announcements of the last `claude-events-toast-quiet'
seconds.")

(defun claude-events--toast-p (item)
  (memq (plist-get item :class) '(n e)))

(defun claude-events--toast (text ts)
  "Announce TEXT for an event at TS, unless the same was said just before."
  (setq claude-events--toasted
        (seq-filter (lambda (cell) (< (abs (- ts (cdr cell))) claude-events-toast-quiet))
                    claude-events--toasted))
  (unless (assoc text claude-events--toasted)
    (push (cons text ts) claude-events--toasted)
    (message "Claude: %s" text)
    (unless (get-buffer-window claude-events-buffer-name t)
      (setq claude-events--unread t))))

(defun claude-events--note-mcp (item)
  "Remember a removed MCP server of ITEM, or forget one that came back."
  (pcase (plist-get item :event)
    ("McpRemoved"
     (setf (alist-get (plist-get item :summary) claude-events--mcp-removed nil nil #'equal)
           (plist-get item :ts)))
    ("McpAdded"
     (setf (alist-get (plist-get item :summary) claude-events--mcp-removed nil 'remove #'equal)
           nil))))

(defun claude-events--check-mcp (&optional now)
  "Announce, once, each MCP server that stayed removed for
`claude-events-mcp-grace' seconds.
Servers reconnect all the time; a removal that is undone within that is not
news."
  (let ((now (or now (float-time))))
    (dolist (cell claude-events--mcp-removed)
      (when (> (- now (cdr cell)) claude-events-mcp-grace)
        (setq claude-events--mcp-removed (delq cell claude-events--mcp-removed))
        (claude-events--toast (format "MCP server %s gone for over %ds"
                                      (car cell) claude-events-mcp-grace)
                              now)))))

(defun claude-events--add (item toast)
  "Record ITEM (newest first); when TOAST, announce it if it deserves that."
  (let ((dup (and (equal (plist-get item :event) "ApiError")
                  (cl-find-if (lambda (o) (and (equal (plist-get o :event) "StopFailure")
                                               (equal (plist-get o :kind) (plist-get item :kind))
                                               (< (abs (- (plist-get o :ts) (plist-get item :ts))) 15)))
                              claude-events--items))))
    (unless dup
      (push item claude-events--items)
      (when (> (length claude-events--items) claude-events-max)
        (setq claude-events--items (take claude-events-max claude-events--items)))
      (when (and (equal (plist-get item :kind) "rate_limit") toast)
        (when-let* ((at (claude-events--reset-time (plist-get item :summary) (plist-get item :ts))))
          (setq claude-events--rate-until at)))
      (when toast
        (claude-events--note-mcp item)
        (when (claude-events--toast-p item)
          (claude-events--toast (format "%s %s" (plist-get item :event) (plist-get item :summary))
                                (plist-get item :ts))))
      (setq claude-events--stall-for nil))))

(defun claude-events--new-lines (file pos)
  "(LINES . NEWPOS): complete lines of FILE after byte POS; a shrunken file
restarts at 0."
  (let ((size (or (file-attribute-size (file-attributes file)) 0)))
    (when (< size pos) (setq pos 0))
    (if (= size pos)
        (cons nil pos)
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file nil pos size)
        (let ((end (save-excursion (goto-char (point-max))
                                   (if (search-backward "\n" nil t) (point) nil))))
          (if (not end)
              (cons nil pos)
            (let ((lines (split-string (decode-coding-string (buffer-substring (point-min) end) 'utf-8) "\n" t)))
              ;; END is the position of the last newline, so also the bytes up to and with it
              (cons lines (+ pos end)))))))))

(defun claude-events--read-log (toast)
  (let ((file (expand-file-name "log.jsonl" claude-events-dir)))
    (when (file-readable-p file)
      (let ((r (claude-events--new-lines file claude-events--log-pos)))
        (setq claude-events--log-pos (cdr r))
        (dolist (line (car r))
          (when-let* ((item (claude-events-parse-hook-line line)))
            (claude-events--add item toast)))))))

(defun claude-events--transcript ()
  (when-let* ((id (and (fboundp 'claude-main-session-id) (claude-main-session-id)))
              (file (expand-file-name (concat id ".jsonl") claude-events-transcript-dir))
              ((file-readable-p file)))
    (unless (equal file claude-events--tx-file)
      (setq claude-events--tx-file file claude-events--tx-pos nil))
    file))

(defun claude-events--read-transcript ()
  "Read what is new at the end of the transcript; the first look only skips to the
end."
  (when-let* ((file (claude-events--transcript)))
    (if (null claude-events--tx-pos)
        (setq claude-events--tx-pos (file-attribute-size (file-attributes file)))
      (let ((r (claude-events--new-lines file claude-events--tx-pos)))
        (setq claude-events--tx-pos (cdr r))
        (dolist (line (car r))
          (dolist (item (claude-events-parse-transcript-line line))
            ;; Only what just happened is news, whatever made an old line come up again
            (claude-events--add item (> (plist-get item :ts) (- (float-time) 30)))))))))

(declare-function claude-bus-tail "claude-bus")
(declare-function claude-bus-path "claude-bus")
(defvar claude-bus-reader)
(defvar claude-events--bus nil "The tail of bus/user/inbox.jsonl: alarms to Cal.")

(defun claude-events--bus-item (m)
  "The event item of the bus message M to Cal."
  (claude-events--item (let ((ts (plist-get m :ts)))
                         (cond ((numberp ts) ts)
                               ((stringp ts) (or (ignore-errors (claude-events--iso-time ts))
                                                 (float-time)))
                               (t (float-time))))
                       "Alarm" nil
                       (or (plist-get m :alarm) "")
                       (format "%s: %s" (or (plist-get m :from) "?") (or (plist-get m :msg) ""))))

(defun claude-events--bus-start ()
  "Follow Cal's inbox on the bus: each new message is a notification with a toast.
The cursor is kept on the bus, so a restart does not announce old alarms again."
  (require 'claude-bus)
  (unless claude-events--bus
    (setq claude-events--bus
          (claude-bus-tail (claude-bus-path "user" "inbox.jsonl")
                           (lambda (m)
                             (claude-events--add (claude-events--bus-item m) t)
                             (claude-events--refresh-view))
                           :cursor claude-bus-reader))))

(defun claude-events--busy-p ()
  "Non-nil when the newest event says the manager is working."
  (when-let* ((last (car claude-events--items)))
    (not (member (plist-get last :event) '("Stop" "StopFailure" "SessionEnd" "Notification" "Alarm" "PermissionRequest")))))

(defun claude-events--check-stall (&optional now)
  (let ((now (or now (float-time))) (last (car claude-events--items)))
    (when (and last (claude-events--busy-p)
               (> (- now (plist-get last :ts)) claude-events-stall-seconds)
               (not (equal claude-events--stall-for (plist-get last :ts))))
      (setq claude-events--stall-for (plist-get last :ts))
      (message "Claude: no event for %ds while busy (last: %s)"
               (round (- now (plist-get last :ts))) (plist-get last :event))
      (unless (get-buffer-window claude-events-buffer-name t) (setq claude-events--unread t)))))

(defun claude-events--tick ()
  (ignore-errors (claude-events--read-log t))
  (ignore-errors (claude-events--read-transcript))
  (ignore-errors (claude-events--check-stall))
  (ignore-errors (claude-events--check-mcp))
  (when (and claude-events--rate-until (> (float-time) claude-events--rate-until))
    (setq claude-events--rate-until nil))
  (when (and claude-events--unread (get-buffer-window claude-events-buffer-name t))
    (setq claude-events--unread nil))
  (claude-events--refresh-view)
  (force-mode-line-update t))

(defun claude-events-mode-line ()
  "\"rate-limited until HH:MM\" while a rate limit is ahead."
  (when (and claude-events--rate-until (> claude-events--rate-until (float-time)))
    (propertize (format-time-string " rate-limited until %H:%M " claude-events--rate-until)
                'face 'warning)))

;;; The buffer

(defvar-keymap claude-events-mode-map
  :parent special-mode-map
  "n" #'claude-events-toggle-n "e" #'claude-events-toggle-e
  "s" #'claude-events-toggle-s "t" #'claude-events-toggle-t
  "g" #'claude-events-reload)

(define-derived-mode claude-events-mode special-mode "Claude-events"
  "Newest-first list of the main session's events.
Filters: SPC m n notifications, e errors, s session, t tools (plain n e s t
without evil, where those are motions); gr reloads (g without evil), q quits."
  (when (fboundp 'claude-header)
    (setq-local header-line-format
                (claude-header "Events" "SPC m n/e/s/t filter · gr reload · q quit"))))

(declare-function evil-define-key* "evil-core")
(declare-function homun-bind-common "claude")
(declare-function homun-bind-leader "claude")
(with-eval-after-load 'evil
  (with-eval-after-load 'claude
    (homun-bind-common claude-events-mode-map #'claude-events-reload)
    (homun-bind-leader 'claude-events-mode 'claude-events-mode-map
                       '(("n" . claude-events-toggle-n) ("e" . claude-events-toggle-e)
                         ("s" . claude-events-toggle-s) ("t" . claude-events-toggle-t)))))

(defun claude-events--visible (items filters)
  (cl-remove-if-not (lambda (i) (memq (plist-get i :class) filters)) items))

(defun claude-events--line (item)
  (format "%s  %-18s %s\n" (format-time-string "%H:%M:%S" (plist-get item :ts))
          (propertize (plist-get item :event) 'face (if (eq (plist-get item :class) 'e) 'error 'shadow))
          (plist-get item :summary)))

(defun claude-events--refresh-view ()
  (when-let* ((buf (get-buffer claude-events-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t) (pt (point)))
        (erase-buffer)
        (insert (propertize (format "Filters: %s%s\n\n"
                                    (mapconcat #'symbol-name claude-events--filters " ")
                                    (homun-key-hint "  (SPC m n notifications, e errors, s session, t tools; gr refresh)"))
                            'face 'shadow))
        (dolist (i (claude-events--visible claude-events--items claude-events--filters))
          (insert (claude-events--line i)))
        (goto-char (min pt (point-max)))))))

(defun claude-events--toggle (class)
  (setq claude-events--filters (if (memq class claude-events--filters)
                                   (remq class claude-events--filters)
                                 (append claude-events--filters (list class))))
  (claude-events--refresh-view))

(defun claude-events-toggle-n () "Toggle notifications." (interactive) (claude-events--toggle 'n))
(defun claude-events-toggle-e () "Toggle errors." (interactive) (claude-events--toggle 'e))
(defun claude-events-toggle-s () "Toggle session events." (interactive) (claude-events--toggle 's))
(defun claude-events-toggle-t () "Toggle tool events." (interactive) (claude-events--toggle 't))

(defun claude-events-reload ()
  "Forget what is shown and read the end of the log again."
  (interactive)
  (setq claude-events--items nil claude-events--log-pos 0)
  (claude-events--load-tail)
  (claude-events--refresh-view))

(defun claude-events--load-tail ()
  "Read the last part of the log without toasting."
  (let* ((file (expand-file-name "log.jsonl" claude-events-dir))
         (size (or (file-attribute-size (file-attributes file)) 0)))
    (setq claude-events--log-pos (max 0 (- size 100000)))
    (claude-events--read-log nil)))

;;;###autoload
(defun claude-events ()
  "Show the event log."
  (interactive)
  (claude-events-start)
  (with-current-buffer (get-buffer-create claude-events-buffer-name)
    (unless (derived-mode-p 'claude-events-mode) (claude-events-mode)))
  (setq claude-events--unread nil)
  (claude-events--refresh-view)
  (display-buffer claude-events-buffer-name)
  (force-mode-line-update t))

;;;###autoload
(defun claude-events-start ()
  "Watch the log and the transcript; idempotent."
  (unless claude-events--timer
    (make-directory claude-events-dir t)
    (claude-events--load-tail)
    (ignore-errors
      (setq claude-events--watch
            (file-notify-add-watch claude-events-dir '(change)
                                   (lambda (_e) (ignore-errors (claude-events--read-log t))
                                     (claude-events--refresh-view)))))
    (ignore-errors (claude-events--bus-start))
    (setq claude-events--timer (run-with-timer 5 5 #'claude-events--tick))
    (add-to-list 'global-mode-string claude-events--mode-string t)))

(defun claude-events--homun-marker (orig &rest args)
  "Add ● to the board's Homun row while a toast is unseen."
  (let ((state (apply orig args)))
    (if claude-events--unread (cons (concat (car state) " ●") (cdr state)) state)))

(with-eval-after-load 'claude-board
  (advice-add 'claude-board--homun-state :around #'claude-events--homun-marker))

;; A reload into a running cockpit starts the bus tail the first start did not have
(when claude-events--timer (ignore-errors (claude-events--bus-start)))

(provide 'claude-events)
;;; claude-events.el ends here
