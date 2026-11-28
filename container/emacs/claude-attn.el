;;; claude-attn.el --- attention ladder: where an alarm to Cal goes, by presence -*- lexical-binding: t -*-

;; One policy point for the alarms to the user (design 5.6/5.7), in the cockpit until homund.
;; The marker at the start of the message sets the level: 🔺 interrupt, 🔸 nudge, else ambient.
;; An interrupt climbs the ladder by Cal's presence: the desktop when he is at it (daemon idle
;; time below `claude-attn-desk-idle'), else the phone when the cockpit gateway saw it lately
;; (its Emacs notifies itself), else an ntfy push (a file in `claude-attn-push-dir' the ntfy
;; service publishes and keeps until it is sent).  Quiet hours hold the push until they end.
;; Every alarm gets one line in `claude-attn-log' with the step it took: nothing is dropped.
;; The desktop heartbeat `presence/desk.json' {device,focused,idle_s,ts} is rewritten every
;; `claude-attn-heartbeat' seconds.  Agents read the best presence in `claude-attn-presence'.

;;; Code:

(require 'cl-lib)
(require 'homun-proc)
(require 'subr-x)
(require 'json)

(defgroup claude-attn nil "The attention ladder." :group 'claude)

(defcustom claude-attn-dir (expand-file-name "~/claude/.services/attn/")
  "Where the ladder keeps its log and the desktop heartbeat."
  :type 'directory)

(defcustom claude-attn-push-dir (expand-file-name "~/claude/.services/ntfy/outbox/")
  "The ntfy service's outbox: one JSON file per push."
  :type 'directory)

(defcustom claude-attn-devices-dir (expand-file-name "~/claude/.services/cockpit-gateway/devices/")
  "The gateway's device directories; a device's `seen' mtime is its last contact."
  :type 'directory)

(defcustom claude-attn-desk-idle 300 "Seconds of idle time up to which Cal counts as at the desktop."
  :type 'integer)

(defcustom claude-attn-phone-seen 90 "Seconds since the gateway last saw a device for it to count as present."
  :type 'integer)

(defcustom claude-attn-heartbeat 30 "Seconds between desktop presence heartbeats." :type 'integer)

(defcustom claude-attn-quiet nil "Non-nil holds interrupt pushes during the quiet hours." :type 'boolean)
(defcustom claude-attn-quiet-start 0 "Hour (0-23) the quiet hours start." :type 'integer)
(defcustom claude-attn-quiet-end 0 "Hour (0-23) the quiet hours end; equal to the start is no hours." :type 'integer)

(defvar claude-attn-notify-function #'message "Called with a string for the desktop step.")
(defvar claude-attn--held nil "Interrupts held by the quiet hours: plists, oldest last.")
(defvar claude-attn--recent nil "The last decisions, newest first: (TIME LEVEL STEP TEXT).")
(defvar claude-attn--timer nil)
(defvar claude-attn--tail nil)

(defun claude-attn-level (msg)
  "The level of the alarm text MSG: `interrupt', `nudge' or `ambient'."
  (let ((msg (or msg "")))
    (cond ((string-prefix-p "🔺" msg) 'interrupt)
          ((string-prefix-p "🔸" msg) 'nudge)
          (t 'ambient))))

(defun claude-attn-quiet-p (hour)
  "Non-nil when HOUR (0-23) lies in the quiet hours, which may wrap past midnight."
  (and claude-attn-quiet
       (let ((s claude-attn-quiet-start) (e claude-attn-quiet-end))
         (cond ((= s e) nil)
               ((< s e) (and (>= hour s) (< hour e)))
               (t (or (>= hour s) (< hour e)))))))

(defun claude-attn--idle ()
  (let ((idle (current-idle-time))) (if idle (float-time idle) 0.0)))

(defun claude-attn--device-age (dir)
  "Seconds since the device directory DIR was last seen, or nil."
  (when-let* ((attrs (file-attributes (expand-file-name "seen" dir))))
    (- (float-time) (float-time (file-attribute-modification-time attrs)))))

(defun claude-attn-phone-p ()
  "Non-nil when some paired device was seen by the gateway lately."
  (and (file-directory-p claude-attn-devices-dir)
       (cl-some (lambda (dir) (when-let* ((age (claude-attn--device-age dir))) (< age claude-attn-phone-seen)))
                (directory-files claude-attn-devices-dir t "\\`[^.]"))))

(defun claude-attn-presence ()
  "The best presence now: `desk', `mobile' or `away'."
  (cond ((< (claude-attn--idle) claude-attn-desk-idle) 'desk)
        ((claude-attn-phone-p) 'mobile)
        (t 'away)))

(defun claude-attn-step (level presence quiet)
  "The step an alarm of LEVEL takes for PRESENCE, QUIET being the hour state."
  (pcase level
    ('ambient 'ambient)
    ('nudge 'nudge)
    (_ (pcase presence
         ('desk 'desk)
         ('mobile 'phone)
         (_ (if quiet 'held 'push))))))

(defun claude-attn--append (file line)
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region (concat (json-serialize line) "\n") nil file t 'silent)))

(defun claude-attn--record (level step text)
  (push (list (float-time) level step text) claude-attn--recent)
  (setq claude-attn--recent (take 50 claude-attn--recent))
  (claude-attn--append (expand-file-name "log.jsonl" claude-attn-dir)
                       (list :ts (floor (float-time)) :level (symbol-name level)
                             :step (symbol-name step) :text (or text ""))))

(defun claude-attn--push (m)
  "Write the push file for the alarm M; the ntfy service sends it."
  (make-directory claude-attn-push-dir t)
  (let* ((id (format "%s-%s" (format-time-string "%s%N") (random 10000)))
         (file (expand-file-name (concat id ".json") claude-attn-push-dir))
         (coding-system-for-write 'utf-8-unix))
    (write-region (json-serialize (list :id id :title (format "%s: %s" (or (plist-get m :from) "homun")
                                                                     (or (plist-get m :alarm) "alarm"))
                                        :body (or (plist-get m :msg) "")))
                  nil (concat file ".tmp") nil 'silent)
    (rename-file (concat file ".tmp") file t)))

(defun claude-attn-handle (m &optional hour)
  "Run the ladder for the alarm M (a plist with :msg); return the step taken."
  (let* ((text (plist-get m :msg))
         (level (claude-attn-level text))
         (quiet (claude-attn-quiet-p (or hour (decoded-time-hour (decode-time)))))
         (step (claude-attn-step level (claude-attn-presence) quiet)))
    (pcase step
      ('desk (funcall claude-attn-notify-function (format "%s" text)))
      ('push (claude-attn--push m))
      ('held (setq claude-attn--held (append claude-attn--held (list m)))))
    (claude-attn--record level step text)
    step))

(defun claude-attn-release (&optional hour)
  "Deliver the held interrupts once the quiet hours are over; return how many."
  (unless (claude-attn-quiet-p (or hour (decoded-time-hour (decode-time))))
    (let ((held claude-attn--held))
      (setq claude-attn--held nil)
      (dolist (m held) (claude-attn-handle m))
      (length held))))

(defun claude-attn-heartbeat ()
  "Write the desktop heartbeat and release what the quiet hours held."
  (claude-attn--append-heartbeat)
  (claude-attn-release))

(defun claude-attn--append-heartbeat ()
  "Write the desktop heartbeat through `homund presence beat' (the file is
homund's)."
  (when-let* ((homund (executable-find "homund")))
    (let ((process-environment (cons (concat "ATTN_DIR=" (directory-file-name claude-attn-dir))
                                     process-environment)))
      (homun-proc-async "presence beat" homund
                        (list "presence" "beat"
                              (if (cl-some (lambda (f) (eq (frame-focus-state f) t)) (frame-list)) "true" "false")
                              (number-to-string (floor (claude-attn--idle))))
                        nil))))

(defun claude-attn-show ()
  "Show the ladder's recent decisions."
  (interactive)
  (with-current-buffer (get-buffer-create "*claude-attn*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "presence: %s   held: %d\n\n" (claude-attn-presence) (length claude-attn--held)))
      (dolist (r claude-attn--recent)
        (insert (format "%s  %-9s %-7s %s\n" (format-time-string "%F %T" (nth 0 r)) (nth 1 r) (nth 2 r)
                        (string-limit (replace-regexp-in-string "\n" " " (or (nth 3 r) "")) 100)))))
    (special-mode)
    (pop-to-buffer (current-buffer))))

(declare-function claude-bus-tail "claude-bus")
(declare-function claude-bus-path "claude-bus")

(defun claude-attn-start ()
  "Follow the alarms to the user and keep the heartbeat going."
  (require 'claude-bus)
  (unless claude-attn--tail
    (setq claude-attn--tail
          (claude-bus-tail (claude-bus-path "user" "inbox.jsonl") #'claude-attn-handle)))
  (unless claude-attn--timer
    (setq claude-attn--timer (run-with-timer 0 claude-attn-heartbeat #'claude-attn-heartbeat))))

(provide 'claude-attn)
;;; claude-attn.el ends here
