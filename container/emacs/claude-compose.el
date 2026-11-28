;;; claude-compose.el --- Compose Markdown messages to the manager's main session -*- coding: utf-8; lexical-binding: t -*-

;; `claude-compose' opens *claude-compose* in a bottom side window under a transcript of the main session (or
;; from the board's "Manager (main)" row); C-c C-c pipes the text to `claude-cal send', which
;; delivers it over the private cal socket as <channel source="cal"> (see docs/development.md of the
;; launcher: only this Emacs writes to that socket).  Agent transcripts are read-only.

(require 'homun-layout)
(require 'ring)
(require 'claude)
(require 'claude-agent)
(require 'claude-outbox)
(require 'claude-identity)
(require 'homun-menu)
(require 'homun-button)
(require 'subr-x)

(defgroup claude-compose nil "Messages from the user to the manager's main session." :group 'tools)

(defcustom claude-compose-auto-open t
  "Non-nil: showing the main session's transcript also opens the compose split."
  :type 'boolean)

(defcustom claude-compose-program
  (list "python3" (expand-file-name "~/claude/_tools/homun/bin/claude-cal") "send")
  "The command that reads a message on stdin and delivers it."
  :type '(repeat string))

(defcustom claude-compose-height 0.33
  "Height of the compose window: a fraction of the frame (0.33) or a number of
lines.
Only the first display uses it; resize the window freely after that."
  :type '(choice (float :tag "Fraction of the frame") (integer :tag "Lines")))

(defcustom claude-compose-mechanic-program
  (list "python3" (expand-file-name "~/claude/_tools/homun/bin/claude-mechanic-request"))
  "the Mechanic's request command; the route adds `repair from cal -' to send and
`who' to ask."
  :type '(repeat string))

(defvar claude-compose-history-file
  (expand-file-name "state/compose-history" (bound-and-true-p claude-service-dir))
  "Where sent messages are kept between sessions, as one Lisp list.")

(defvar claude-compose-history-size 100 "How many sent messages are remembered.")

(defvar claude-compose--history nil "Ring of sent messages, newest first; nil until used.")
(defvar-local claude-compose--index nil "Position in the history while browsing, else nil.")
(defvar-local claude-compose--draft nil "The text typed before browsing the history.")

(defvar claude-board-main-dir)
(defvar claude-transcript--file)
(defvar claude-transcript-focus--file)
(declare-function claude-board--task "claude-board")
(declare-function claude-board-open "claude-board")
(declare-function claude-board--mains "claude-board")
(declare-function claude-board--role-file "claude-board")
(declare-function claude-bus-user-withdraw "claude-bus")
(declare-function claude-transcript-open "claude-transcript")
(declare-function claude-transcript-buffer "claude-transcript")
(declare-function evil-insert-state "evil-states")
(declare-function evil-define-minor-mode-key "evil-core")
(declare-function homun-layout-focus-toggle "homun-layout")
(declare-function homun-layout-clear "homun-layout")

;;; Routes
;; Each box has a route: the role it talks to, the command that sends, the command that says who
;; is on the other end.  *claude-compose* is the Manager's; *claude-compose: Mechanic* the mechanic's
;; (the user's words go through `claude-mechanic-request cal', which writes the Mechanic's cal-inbox: only this container mounts it writable).
;; The queue is the Manager's only: the Mechanic's box sends at once, and refuses while it is offline.
;;
;; The bus (stage 5): while a role's channel server shows its bus/<role>/reader-ok heartbeat,
;; any role's box sends by writing bus/<role>/user/host/<ns> (`claude-bus-user-write'); the
;; box is read-only to the role, whose reader marks each message in bus/<role>/user-state/host/
;; (sending/, then claimed/ or failed/); the compose box shows where it is from those markers
;; and prunes delivered messages from the box every minute.  The cal socket and the send state machine below stay only as the fallback
;; while that heartbeat is missing.

(require 'cl-lib)
(declare-function claude-handoff-route-for-file "claude-handoff")
(defvar claude-compose--outbox)
(defvar claude-compose--bus-watches)
(cl-defstruct (claude-compose-route (:constructor claude-compose-route--make))
  role buffer send who)

(defun claude-compose-route (role)
  "The route of ROLE (the symbol `manager' or `mechanic'), or nil."
  (pcase role
    ('manager (claude-compose-route--make
               :role 'manager :buffer "*claude-compose*" :send claude-compose-program
               :who (append (butlast claude-compose-program) '("who"))))
    ('mechanic (claude-compose-route--make
                :role 'mechanic :buffer (format "*claude-compose: %s*" (claude-role-name 'mechanic))
                :send (append claude-compose-mechanic-program '("cal" "-"))
                :who (append claude-compose-mechanic-program '("who"))))
    ((pred symbolp)
     (claude-compose-route--make
      :role role :buffer (format "*claude-compose: %s*" (claude-role-name role))))))

(defvar-local claude-compose--route nil "The route of this compose box.")

(defun claude-compose--route ()
  "The route of the current box (the Manager's outside one)."
  (or claude-compose--route (claude-compose-route 'manager)))

(defun claude-compose--manager-p ()
  (eq (claude-compose-route-role (claude-compose--route)) 'manager))

(defun claude-compose--route-for-file (file)
  "The route of the role whose main session transcript is FILE, or nil (an
agent's)."
  (require 'claude-board)
  (when file
    (or (and (claude-compose--main-file-p file) (claude-compose-route 'manager))
        (when-let* ((task (seq-find (lambda (task)
                                      (and (eq (plist-get task :kind) 'main)
                                           (plist-get task :transcript)
                                           (file-equal-p (plist-get task :transcript) file)))
                                    (claude-board--mains))))
          (claude-compose-route (plist-get task :role)))
        (and (require 'claude-handoff nil t) (claude-handoff-route-for-file file)))))

;;; Which session

(defun claude-compose--main-file ()
  "The main session's transcript: the pinned one, else the newest in
`claude-board-main-dir'."
  (require 'claude)
  (require 'claude-board)
  (claude-board--role-file 'manager claude-board-main-dir))

(defun claude-compose--main-file-p (file)
  "Non-nil when FILE is the main session's transcript."
  (when-let* ((file) (main (claude-compose--main-file)))
    (file-equal-p file main)))

;;; Working status
;; The main transcript is read on a file-notify change (debounced), and only the bytes added
;; since the last read: each line is parsed once.  While the manager works a 1 s timer only advances
;; the clock; idle, nothing runs.

(defvar claude-compose-status-interval 1
  "Seconds between clock updates of the working status while the manager works.")

(defvar claude-compose-tail-bytes 131072
  "How much of a transcript the first read takes, from its end.")

(defvar claude-compose--status-timer nil "The clock timer, alive only while the manager works.")
(defvar claude-compose--info nil "The current turn as (:start TIME :call BLOCK), nil when idle.")
(defvar claude-compose--status-watch nil)
(defvar claude-compose--debounce nil)
(defvar claude-compose--tail nil
  "What is known of the main transcript: (:file :offset :start :call :ended).")

(defun claude-compose--notice-p (entry)
  "Non-nil when ENTRY is a task notification, which the transcript logs as a user
entry without a reply of its own: it must not make an ended turn look like work."
  (and (equal (alist-get 'type entry) "user")
       (let ((content (alist-get 'content (alist-get 'message entry))))
         (and (stringp content) (string-prefix-p "<task-notification" content)))))

(defun claude-compose--strings (x)
  "The strings inside the JSON value X."
  (cond ((stringp x) (list x))
        ((vectorp x) (mapcan #'claude-compose--strings (append x nil)))
        ((consp x) (mapcan #'claude-compose--strings
                           (if (consp (car x)) x (list (cdr x)))))))

(defun claude-compose--entry-seen (entry)
  "Count the user's outbox messages that ENTRY carries as seen.
A message sent mid-turn comes as hook context, an attachment or a system
reminder, not as a user entry: its text inside a <channel> tag counts in a user
or attachment entry, the ones the transcript draws.  Any other (the manager's,
a queue-operation that only notes the message waits) would take the message
out of the outbox before the transcript shows it, so it would vanish and come
back."
  (when (member (alist-get 'type entry) '("user" "attachment"))
    (when claude-compose--outbox
      (dolist (s (claude-compose--strings entry))
        (dolist (m claude-compose--outbox)
          (let ((text (string-trim (plist-get m :text))))
            (when (and (not (eq (plist-get m :state) 'failed))
                       (or (string= (string-trim s) text)
                           (string-search (concat ">" text "</channel>") s)))
              (claude-compose-seen text))))))))

(defun claude-compose--tail-take (state entry)
  "STATE with the transcript ENTRY folded in."
  (let ((type (alist-get 'type entry))
        (message (alist-get 'message entry)))
    (claude-compose--entry-seen entry)
    (cond
     ((claude-compose--notice-p entry))
     ((equal type "user")
      (let ((content (alist-get 'content message)))
        (unless (and (vectorp content)
                     (seq-some (lambda (block) (equal (alist-get 'type block) "tool_result"))
                               content))
          (plist-put state :start (ignore-errors
                                    (float-time (date-to-time (alist-get 'timestamp entry)))))
          (plist-put state :call nil)))
      (plist-put state :ended nil))
     ((equal type "assistant")
      (let ((content (alist-get 'content message)))
        (when-let* (((vectorp content))
                    (call (seq-find (lambda (block) (equal (alist-get 'type block) "tool_use"))
                                    content)))
          (plist-put state :call call)))
      (plist-put state :ended (equal (alist-get 'stop_reason message) "end_turn"))))
    state))

(defun claude-compose--tail-read ()
  "Fold what was added to the main transcript since the last read; return the
state."
  (let* ((file (claude-compose--main-file))
         (size (and file (file-attribute-size (file-attributes file))))
         (state claude-compose--tail))
    (when (or (null state) (not (equal file (plist-get state :file)))
              (and size (< size (plist-get state :offset))))
      (setq state (list :file file :offset (max 0 (- (or size 0) claude-compose-tail-bytes))
                        :start nil :call nil :ended t :cut t)))
    (when (and size (> size (plist-get state :offset)))
      (with-temp-buffer
        (insert-file-contents-literally file nil (plist-get state :offset) size)
        (goto-char (point-min))
        (when (and (plist-get state :cut) (> (plist-get state :offset) 0))
          (forward-line 1))                ; the first line may be cut
        (let ((from (point)))
          (while (search-forward "\n" nil t)
            (when-let* ((entry (ignore-errors
                                 (json-parse-string
                                  (decode-coding-string (buffer-substring from (1- (point))) 'utf-8)
                                  :object-type 'alist))))
              (setq state (claude-compose--tail-take state entry)))
            (setq from (point)))
          (setq state (plist-put state :offset (+ (plist-get state :offset) (1- from))))
          (setq state (plist-put state :cut nil)))))
    (setq claude-compose--tail state)))

(defun claude-compose--info-read ()
  "The current turn, or nil when the manager's turn has ended."
  (let ((state (claude-compose--tail-read)))
    (unless (plist-get state :ended)
      (list :start (plist-get state :start) :call (plist-get state :call)))))

(defun claude-compose--status-string (info)
  "The working text for INFO, with the clock at the present."
  (let* ((call (plist-get info :call))
         (input (alist-get 'input call))
         (elapsed (and (plist-get info :start) (- (float-time) (plist-get info :start)))))
    (concat (propertize (format " %s working" claude-agent-emoji) 'face 'warning)
            (and elapsed (format " %d:%02d" (/ (truncate elapsed) 60) (% (truncate elapsed) 60)))
            (and call
                 (propertize
                  (format "  %s %s" (alist-get 'name call)
                          (truncate-string-to-width
                           (or (alist-get 'description input) (alist-get 'command input) "")
                           60 nil nil "…"))
                  'face 'shadow)))))

(defun claude-compose--status ()
  "What the manager is doing right now, or nil when its turn has ended."
  (when-let* ((info (claude-compose--info-read)))
    (claude-compose--status-string info)))

(defvar claude-compose-status-string nil "The manager's working status for the mode line, or nil.")
(put 'claude-compose-status-string 'risky-local-variable t)

(defun claude-compose--render ()
  "Rebuild `claude-compose-status-string' from the cached turn."
  (let ((string (and claude-compose--info (claude-compose--status-string claude-compose--info))))
    (unless (equal string claude-compose-status-string)
      (setq claude-compose-status-string string)
      (force-mode-line-update t))))

(defun claude-compose--status-update (&rest _)
  "Read what the transcript added; keep the clock timer only while the manager
works; pump when idle."
  (setq claude-compose--info (ignore-errors (claude-compose--info-read)))
  (cond ((and claude-compose--info (not claude-compose--status-timer))
         (setq claude-compose--status-timer
               (run-with-timer claude-compose-status-interval claude-compose-status-interval
                               #'claude-compose--render)))
        ((and (null claude-compose--info) claude-compose--status-timer)
         (cancel-timer claude-compose--status-timer)
         (setq claude-compose--status-timer nil)))
  (unless claude-compose--info (claude-compose--pump))
  (claude-compose--render))

;; The status sits in the header line of transcript buffers: no advice on a mode line package.
(defconst claude-compose--header '(:eval claude-compose-status-string))

(defun claude-compose--status-place ()
  "Show the working status in the header line of every transcript buffer, now and
later."
  (add-hook 'claude-transcript-mode-hook #'claude-compose--header-set)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'claude-transcript-mode) (claude-compose--header-set)))))

(defun claude-compose--header-set ()
  (unless (member claude-compose--header (ensure-list header-line-format))
    (setq-local header-line-format
                (if header-line-format
                    (list claude-compose--header header-line-format)
                  claude-compose--header))))

;; The watch is on the directory: a transcript may be created after the watch.
(defun claude-compose--status-changed (event)
  "File-notify callback: a transcript changed (EVENT); read it once things settle."
  (when (string-suffix-p ".jsonl" (nth 2 event))
    (when claude-compose--debounce (cancel-timer claude-compose--debounce))
    (setq claude-compose--debounce
          (run-with-timer 0.3 nil #'claude-compose--status-update))))

(defun claude-compose--status-start ()
  "Show the working status in the mode line, driven by file-notify on the
transcripts."
  (require 'claude-board)
  (require 'filenotify)
  (claude-compose--status-place)
  (unless (and claude-compose--status-watch (file-notify-valid-p claude-compose--status-watch))
    (setq claude-compose--status-watch
          (file-notify-add-watch claude-board-main-dir '(change)
                                 #'claude-compose--status-changed)))
  (claude-compose--status-update))

;;; Outbox
;; Every message to the manager is first a file queue/<ns timestamp>, then sent one at a time, oldest
;; first, while the manager is idle; mid-turn cal-queue-hook.sh claims the files at the manager's next tool
;; step.  Both sides claim a file by renaming it (Emacs into queue/sending/, the hook into
;; queue/claimed/), so a message goes out once.  A failed one moves to queue/failed/ and writes
;; queue/paused, which holds the hook too, so nothing overtakes it; C-c C-r retries it,
;; C-c C-d drops it.  The transcript shows the outbox as the user's messages with their state.

(defvar claude-compose-queue-dir
  (expand-file-name "queue" (or (getenv "CAL_CHANNEL_DIR") "~/claude/.services/cal"))
  "Where queued messages wait; the hook claims them from here.")

(defvar claude-compose--outbox nil
  "The user's messages the manager has not been seen to receive, oldest first:
plists
\(:id NAME :text TEXT :sha SHA :state pending|held|sending|sent|failed :error TEXT
:time FLOAT).")

(defvar claude-compose-outbox-functions nil
  "Functions called with no arguments, from a timer, after the outbox changed.")

(defvar claude-compose-sent-keep 3600
  "Seconds a sent message stays in the outbox when no transcript sees it arrive.")

(defcustom claude-compose-spin-min 0.6
  "Seconds a direct send shows as sending at least, so the spinner can be seen."
  :type 'number :group 'claude-compose)

(defcustom claude-compose-tick-keep 1.0
  "Seconds a delivered direct send shows its ✓ before it leaves the outbox."
  :type 'number :group 'claude-compose)

(defcustom claude-compose-start-grace 180
  "Seconds a message waits for the manager to bind the channel after a Manager
start.
A send refused as \"not listening\" inside this time (counted from the message)
while the Manager is starting stays queued and is retried; after it the message
fails."
  :type 'natnum :group 'claude-compose)

(defvar claude-compose-retry-interval 4 "Seconds between sends while the manager is starting.")
(defvar claude-compose--held nil
  "Non-nil while the transcript is focused: pending messages are held, nothing is sent.")
(defvar claude-compose--hold-until 0.0 "Float time before which the pump does not send.")

(defvar claude-compose--process nil "The delivery in flight, or nil.")
(defvar claude-compose--queue-watch nil "The file-notify descriptor of the queue dir.")
(defvar claude-compose--notify-timer nil)

(defun claude-compose--queue-path (id &optional sub)
  "The file of message ID in the queue dir, or in its subdirectory SUB."
  (expand-file-name id (if sub (expand-file-name sub claude-compose-queue-dir)
                         claude-compose-queue-dir)))

(defun claude-compose--queue-names (&optional sub)
  "The names of the messages in the queue dir (or its SUB), oldest first."
  (let ((dir (if sub (expand-file-name sub claude-compose-queue-dir) claude-compose-queue-dir)))
    (and (file-directory-p dir) (directory-files dir nil "\\`[0-9]+\\'"))))

(defun claude-compose--file-text (file)
  "The text in FILE, or nil when it is gone."
  (ignore-errors
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8)) (insert-file-contents file))
      (buffer-string))))

(defun claude-compose--sha (text)
  "The sha256 of TEXT as the channel logs it."
  (secure-hash 'sha256 (encode-coding-string text 'utf-8)))

(defun claude-compose--get (id)
  (seq-find (lambda (m) (equal (plist-get m :id) id)) claude-compose--outbox))

(defun claude-compose--failed ()
  "The failed message that holds the queue, or nil.  A stale one (a claimed file
that never arrived, :stale) is shown and can be retried or dropped, but holds
nothing."
  (seq-find (lambda (m) (and (eq (plist-get m :state) 'failed) (not (plist-get m :stale))))
            claude-compose--outbox))

(defun claude-compose--failed-any ()
  "A failed message of either kind, the one holding the queue first."
  (or (claude-compose--failed)
      (seq-find (lambda (m) (eq (plist-get m :state) 'failed)) claude-compose--outbox)))

(defvar claude-compose-claimed-stale 600
  "Seconds after which a file left in queue/claimed/ counts as not arrived.")

(defun claude-compose--claim-stale-p (id)
  (when-let* ((attrs (file-attributes (claude-compose--queue-path id "claimed"))))
    (> (- (float-time) (float-time (file-attribute-status-change-time attrs)))
       claude-compose-claimed-stale)))

(defun claude-compose--claimed-sync (claimed)
  "Match the outbox to the hook's CLAIMED files: logged ones are sent, old unlogged
ones show as failed (:stale), a stale one whose file went away leaves."
  (dolist (id claimed)
    (let ((m (claude-compose--get id)))
      (when (and (or (null m) (memq (plist-get m :state) '(pending held)))
                 (not (file-exists-p (claude-compose--queue-path id))))
        (let ((text (or (and m (plist-get m :text))
                        (claude-compose--file-text (claude-compose--queue-path id "claimed")))))
          (cond ((null text))
                ((claude-compose--logged-p (claude-compose--sha text))
                 (when m (claude-outbox-move m 'sent)))
                ((claude-compose--claim-stale-p id)
                 (when m (setq claude-compose--outbox (delq m claude-compose--outbox)))
                 (plist-put (claude-compose--add id text 'failed
                                                 "claimed but may not have arrived")
                            :stale t)))))))
  (dolist (m claude-compose--outbox)
    (when (and (plist-get m :stale) (not (member (plist-get m :id) claimed)))
      (setq claude-compose--outbox (delq m claude-compose--outbox)))))

(defun claude-compose--add (id text state &optional error)
  "Put message ID with TEXT into the outbox in STATE, in name order."
  (let ((m (list :id id :text text :sha (claude-compose--sha text) :state state :error error
                 :time (/ (string-to-number id) 1e9))))
    (setq claude-compose--outbox
          (sort (cons m claude-compose--outbox)
                (lambda (a b) (string< (plist-get a :id) (plist-get b :id)))))
    m))

(defun claude-compose--set (m state &optional error)
  "Move message M to STATE (with ERROR when it failed)."
  (claude-outbox-move m state error)
  (claude-compose--changed))

(defun claude-compose--settle (m error)
  "Record the end of the direct send M (ERROR nil when delivered) in its state.
The state is the only thing the transcript draws from: it stays `sending' until
`claude-compose-spin-min' has passed, a delivered M is `sent' for
`claude-compose-tick-keep' and then leaves, a refused one is `failed' (retry or
drop).  M's :hold is the time before which `claude-compose-seen' leaves it in
place."
  (let ((wait (max 0 (- (+ (plist-get m :time) claude-compose-spin-min) (float-time)))))
    (plist-put m :hold (+ (float-time) wait (if error 0 claude-compose-tick-keep)))
    (run-at-time
     wait nil
     (lambda ()
       (when (memq m claude-compose--outbox)
         (if error
             (claude-compose--set m 'failed error)
           (claude-compose--set m 'sent)
           (run-at-time claude-compose-tick-keep nil
                        (lambda ()
                          (when (eq (plist-get m :state) 'sent)
                            (setq claude-compose--outbox (delq m claude-compose--outbox))
                            (claude-compose--changed))))))))))

(defun claude-compose--pause (on)
  "Hold the hook (ON non-nil) or let it go again."
  (let ((file (claude-compose--queue-path "paused")))
    (cond ((and on (not (file-exists-p file))) (write-region "" nil file nil 'silent))
          ((and (not on) (file-exists-p file)) (ignore-errors (delete-file file))))))

(defun claude-compose--changed ()
  "Prune the outbox, hold the hook while a message failed, tell the viewers soon."
  (let ((now (float-time)))
    (setq claude-compose--outbox
          (seq-remove (lambda (m) (and (eq (plist-get m :state) 'sent)
                                       (> (- now (plist-get m :time)) claude-compose-sent-keep)))
                      claude-compose--outbox)))
  (claude-outbox-hold claude-compose--outbox claude-compose--held)
  (let ((hold (and (or (claude-compose--failed) claude-compose--held) t)))
    (ignore-errors (claude-compose--pause hold))
    (when (assq 'manager claude-compose--bus-watches)
      (ignore-errors (claude-bus-user-pause 'manager hold))))
  (force-mode-line-update t)
  (unless (timerp claude-compose--notify-timer)
    (setq claude-compose--notify-timer
          (run-at-time 0 nil (lambda ()
                               (setq claude-compose--notify-timer nil)
                               (run-hooks 'claude-compose-outbox-functions))))))

(defun claude-compose--enqueue (text)
  "Write TEXT as the newest queued message and start delivering."
  (make-directory claude-compose-queue-dir t)
  (set-file-modes claude-compose-queue-dir #o700)
  (let ((id (format-time-string "%s%N"))
        (tmp (make-temp-file (expand-file-name ".tmp" claude-compose-queue-dir))))
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region text nil tmp nil 'silent))
    (rename-file tmp (claude-compose--queue-path id))
    (claude-compose--add id text 'pending)
    (claude-compose--changed)
    (claude-compose--pump)))

(defun claude-compose--logged-p (sha)
  "Non-nil when the channel log's tail has a message with SHA."
  (let ((log (expand-file-name "log.jsonl" (file-name-directory
                                            (directory-file-name claude-compose-queue-dir)))))
    (ignore-errors
      (with-temp-buffer
        (let ((size (file-attribute-size (file-attributes log))))
          (insert-file-contents-literally log nil (max 0 (- size 65536)) size))
        (search-forward sha nil t)))))

(defun claude-compose--sync (&rest _)
  "Match the outbox to the queue dir: adopt files written before this Emacs, and
mark the messages the hook took (gone from queue/ and queue/claimed/) by the
channel log."
  (let ((queued (claude-compose--queue-names))
        (claimed (claude-compose--queue-names "claimed")))
    (dolist (id queued)
      (unless (claude-compose--get id)
        (when-let* ((text (claude-compose--file-text (claude-compose--queue-path id))))
          (claude-compose--add id text 'pending))))
    (dolist (id (claude-compose--queue-names "failed"))
      (unless (claude-compose--get id)
        (when-let* ((text (claude-compose--file-text (claude-compose--queue-path id "failed"))))
          (claude-compose--add id text 'failed "failed before this Emacs started"))))
    (claude-compose--claimed-sync claimed)
    (ignore-errors (claude-compose--bus-sync))
    (dolist (m claude-compose--outbox)
      (when (and (memq (plist-get m :state) '(pending held)) (not (plist-get m :bus))
                 (not (member (plist-get m :id) queued))
                 (not (member (plist-get m :id) claimed)))
        (if (claude-compose--logged-p (plist-get m :sha))
            (claude-outbox-move m 'sent)
          (claude-outbox-move m 'failed "left the queue but is not in the channel log"))))
    (claude-compose--changed)))

(defun claude-compose--start (command text done)
  "Run COMMAND with TEXT on its stdin; call DONE with nil, or the error text, when
it ends."
  (let ((out (generate-new-buffer " *claude-compose-send*" t)))
    (condition-case err
        (let ((proc (make-process
                     :name "claude-compose-send" :buffer out :noquery t :connection-type 'pipe
                     :coding 'utf-8-unix :command command
                     :sentinel
                     (lambda (proc _event)
                       (unless (process-live-p proc)
                         (let ((status (process-exit-status proc))
                               (output (with-current-buffer out (string-trim (buffer-string)))))
                           (kill-buffer out)
                           (funcall done
                                    (unless (eql status 0)
                                      (if (string-empty-p output)
                                          (format "exit %s" status)
                                        (string-remove-prefix "claude-cal: " output))))))))))
          (process-send-string proc text)
          (process-send-eof proc)
          proc)
      (error (kill-buffer out)
             (funcall done (error-message-string err))
             nil))))

(defvar claude-compose-manager-dir nil
  "The Manager's state directory (boot record, heartbeat); nil: `manager' beside
the cal directory.")

(defun claude-compose--manager-file (name)
  (expand-file-name name (or claude-compose-manager-dir
                             (expand-file-name
                              "manager" (file-name-directory
                                         (directory-file-name
                                          (file-name-directory
                                           (directory-file-name claude-compose-queue-dir))))))))

(defun claude-compose--file-age (file)
  "Seconds since FILE was modified, or nil when it is not there."
  (when-let* ((attrs (file-attributes file)))
    (- (float-time) (float-time (file-attribute-modification-time attrs)))))

(defun claude-compose--starting-p ()
  "Non-nil while the Manager is booting: its boot record is under five minutes old,
or its heartbeat under two minutes."
  (let ((boot (claude-compose--file-age (claude-compose--manager-file "boot")))
        (beat (claude-compose--file-age (claude-compose--manager-file "heartbeat"))))
    (or (and boot (< boot 300)) (and beat (< beat 120)))))

(defun claude-compose--wait-p (m error)
  "Non-nil when message M's send ERROR is just the manager not listening yet."
  (and (string-match-p "listening" error)
       (< (- (float-time) (plist-get m :time)) claude-compose-start-grace)
       (claude-compose--starting-p)))

(defun claude-compose--pump ()
  "Send the oldest queued message, unless one is in flight, one failed or the
manager works."
  (unless (or (process-live-p claude-compose--process) claude-compose--info
              (< (float-time) claude-compose--hold-until)
              claude-compose--held
              (claude-compose--failed))
    (when-let* ((id (car (claude-compose--queue-names))))
      (let ((sending (claude-compose--queue-path id "sending"))
            (m (or (claude-compose--get id)
                   (claude-compose--add id (or (claude-compose--file-text
                                                (claude-compose--queue-path id))
                                               "")
                                        'pending))))
        (make-directory (file-name-directory sending) t)
        (if (not (ignore-errors (rename-file (claude-compose--queue-path id) sending) t))
            (claude-compose--sync)      ; the hook took it first
          (claude-compose--set m 'sending)
          (setq claude-compose--process
                (claude-compose--start
                 (claude-compose-route-send (claude-compose-route 'manager))
                 (plist-get m :text)
                 (lambda (error)
                   (setq claude-compose--process nil)
                   (cond
                    ((and error (claude-compose--wait-p m error))
                     ;; Back into the queue, tried again soon: the Manager is still starting
                     (ignore-errors (rename-file sending (claude-compose--queue-path id) t))
                     (setq claude-compose--hold-until (+ (float-time) claude-compose-retry-interval))
                     (run-at-time claude-compose-retry-interval nil #'claude-compose--pump)
                     (claude-compose--set m 'pending "The manager is starting — will send when listening"))
                    (error
                       (progn
                         (make-directory (file-name-directory (claude-compose--queue-path id "failed")) t)
                         (ignore-errors (rename-file sending (claude-compose--queue-path id "failed") t))
                         (claude-compose--set m 'failed error)
                         (message "Not sent to %s: %s%s" claude-agent-name error (homun-key-hint " (C-c C-r retry, C-c C-d drop)"))))
                    (t
                     (ignore-errors (delete-file sending))
                     (claude-compose--set m 'sent)
                     (claude-compose--pump)))))))))))

(defun claude-compose-retry ()
  "Queue the failed message again, first in line."
  (interactive)
  (let ((m (or (claude-compose--failed-any) (user-error "No failed message")))
        (coding-system-for-write 'utf-8-unix))
    (if (plist-get m :bus)
        (progn (claude-bus-user-retry (plist-get m :bus) (plist-get m :id))
               (claude-compose--set m 'pending))
    (write-region (plist-get m :text) nil (claude-compose--queue-path (plist-get m :id)) nil 'silent)
    (dolist (sub '("failed" "claimed"))
      (ignore-errors (delete-file (claude-compose--queue-path (plist-get m :id) sub))))
    (plist-put m :stale nil)
    (claude-compose--set m 'pending)
    (claude-compose--pump))))

(defun claude-compose--drop-target ()
  "The message C-c C-d means: the one at point, else the failed one, else the
newest not sent."
  (or (when-let* ((id (get-text-property (point) 'claude-compose-id)))
        (claude-compose--get id))
      (claude-compose--failed-any)
      (car (last (seq-filter (lambda (m) (memq (plist-get m :state) '(pending held sent)))
                             claude-compose--outbox)))
      (user-error "No pending message")))

(defun claude-compose-drop ()
  "Drop a message that is not in the transcript yet; the ones after it go on.
The failed one goes at once; a pending one (at point, else the newest) asks
first."
  (interactive)
  (let* ((m (claude-compose--drop-target))
         (failed (eq (plist-get m :state) 'failed)))
    (when (eq (plist-get m :state) 'sending) (user-error "Still sending"))
    (when (or failed
              (claude-confirm (format "Drop pending message \"%s\"? "
                                (truncate-string-to-width (plist-get m :text) 40 nil nil "…"))))
      (if (plist-get m :bus)
          (claude-bus-user-drop (plist-get m :bus) (plist-get m :id))
        (dolist (sub '(nil "failed" "claimed"))
          (ignore-errors (delete-file (claude-compose--queue-path (plist-get m :id) sub)))))
      (claude-outbox-move m 'cancelled)
      (setq claude-compose--outbox (delq m claude-compose--outbox))
      (claude-compose--changed)
      (claude-compose--pump)
      (message "dropped: %s" (truncate-string-to-width (plist-get m :text) 40 nil nil "…")))))

(defun claude-compose-seen (text)
  "A transcript shows the user's message TEXT: drop the oldest outbox message with
that text.
Return non-nil when there was one."
  (when-let* ((text (string-trim text))
              (m (seq-find (lambda (m) (and (not (eq (plist-get m :state) 'failed))
                                            (not (plist-get m :seen))
                                            (equal (string-trim (plist-get m :text)) text)))
                           claude-compose--outbox)))
    ;; A direct send's mark goes on showing, on the logged line, until its time is over
    (if (> (or (plist-get m :hold) 0) (float-time))
        (plist-put m :seen t)
      (setq claude-compose--outbox (delq m claude-compose--outbox)))
    (claude-compose--changed)
    t))

(defun claude-compose--recover ()
  "After a restart: a message left in queue/sending/ may or may not have arrived."
  (dolist (id (claude-compose--queue-names "sending"))
    (make-directory (file-name-directory (claude-compose--queue-path id "failed")) t)
    (ignore-errors (rename-file (claude-compose--queue-path id "sending")
                                (claude-compose--queue-path id "failed") t))
    (when-let* ((text (claude-compose--file-text (claude-compose--queue-path id "failed"))))
      (unless (claude-compose--get id)
        (claude-compose--add id text 'failed "interrupted while sending; it may have arrived")))))

(defun claude-compose--own-file-p (file)
  "Non-nil when FILE is the pause flag or an enqueue temp file of the queue dir."
  (let ((name (and file (file-name-nondirectory file))))
    (and name (or (equal name "paused") (string-prefix-p ".tmp" name)))))

(defun claude-compose--queue-watch ()
  "Watch the queue dir with file-notify (again, after a reload)."
  (require 'filenotify)
  (make-directory claude-compose-queue-dir t)
  (when claude-compose--queue-watch (ignore-errors (file-notify-rm-watch claude-compose--queue-watch)))
  (setq claude-compose--queue-watch
        (file-notify-add-watch claude-compose-queue-dir '(change)
                               (lambda (event)
                                 ;; Our own `paused' flag and the enqueue temp files are no
                                 ;; news: syncing on them lets two Emacs on one queue
                                 ;; toggle `paused' at each other for ever.
                                 (unless (claude-compose--own-file-p (nth 2 event))
                                   (claude-compose--sync)
                                   (claude-compose--pump))))))

;;; Taking a queued message back

(defun claude-compose--withdraw (m)
  "Take queued message M back before it is claimed: t, or `claimed' when it went
out first.
The bus box has the cockpit as its only writer; the local queue is claimed by
rename."
  (if-let* ((role (plist-get m :bus)))
      (claude-bus-user-withdraw role (plist-get m :id))
    (let ((file (claude-compose--queue-path (plist-get m :id))))
      ;; The pump and the hook claim by renaming too: whoever renames first has it
      (if (ignore-errors (rename-file file (concat file ".withdrawn")) t)
          (progn (ignore-errors (delete-file (concat file ".withdrawn"))) t)
        'claimed))))

(defun claude-compose--take-back (id)
  "Withdraw the pending or held message ID from the outbox as cancelled; return it,
or nil after saying why not."
  (let ((m (claude-compose--get id)))
    (cond ((not (and m (memq (plist-get m :state) '(pending held))))
           (message "That message is not queued any more") nil)
          ((eq (claude-compose--withdraw m) 'claimed)
           (claude-compose--sync)
           (message "Too late: %s took that message already" claude-agent-name) nil)
          (t (claude-outbox-move m 'cancelled)
             (setq claude-compose--outbox (delq m claude-compose--outbox))
             (claude-compose--changed)
             (claude-compose--pump)
             m))))

(defun claude-compose-queued-cancel (id)
  "Cancel the pending message ID: it is not sent."
  (when-let* ((m (claude-compose--take-back id)))
    (message "cancelled: %s" (truncate-string-to-width (plist-get m :text) 40 nil nil "…"))))

(defun claude-compose-queued-edit (id)
  "Take the pending message ID out of the queue into the compose box (above a draft
there), and go there; send it again as usual."
  (when-let* ((m (claude-compose--take-back id)))
    (claude-compose--show)
    (let ((draft (string-trim (claude-compose--input))))
      (claude-compose--set-input
       (if (string-empty-p draft) (plist-get m :text) (concat (plist-get m :text) "\n\n" draft)))
      (goto-char (point-max)))
    (message "back in compose: edit it%s" (homun-key-hint ", C-c C-c sends"))))

;;; Focus: while the transcript is focused the queue holds

(defun claude-compose--focus-update (&rest _)
  "Hold the queue while the transcript is focused, and send again once it is left."
  (let ((held (and (claude-outbox-focused-p) t)))
    (unless (eq held claude-compose--held)
      (setq claude-compose--held held)
      (claude-compose--changed)
      (unless held (claude-compose--pump)))))

(add-hook 'window-selection-change-functions #'claude-compose--focus-update)
(add-hook 'window-buffer-change-functions #'claude-compose--focus-update)
(add-function :after after-focus-change-function #'claude-compose--focus-update)

(defvar claude-compose--claim-timer nil)

(defun claude-compose--claim-timer ()
  "Once a minute, look at the hook's claimed files (a file just gets old: no
event)."
  (when (timerp claude-compose--claim-timer) (cancel-timer claude-compose--claim-timer))
  (setq claude-compose--claim-timer
        (run-with-timer 60 60 (lambda ()
                                (when (claude-compose--queue-names "claimed")
                                  (ignore-errors (claude-compose--sync)))))))

;;; The box

(defun claude-compose--input ()
  "The text being composed."
  (buffer-substring-no-properties (point-min) (point-max)))

(defun claude-compose--set-input (text)
  "Replace the text being composed with TEXT; the same text leaves point and undo
alone."
  (unless (equal text (claude-compose--input))
    (erase-buffer)
    (insert text)))

;;; History

(defun claude-compose--load-history ()
  "The history ring, read from `claude-compose-history-file' on first use."
  (or claude-compose--history
      (let ((ring (make-ring claude-compose-history-size)))
        (when (file-readable-p claude-compose-history-file)
          (dolist (text (reverse (ignore-errors
                                   (with-temp-buffer
                                     (insert-file-contents claude-compose-history-file)
                                     (read (current-buffer))))))
            (when (stringp text) (ring-insert ring text))))
        (setq claude-compose--history ring))))

(defun claude-compose--remember (text)
  "Add TEXT to the history and save it."
  (let ((ring (claude-compose--load-history)))
    (ring-insert ring text)
    (make-directory (file-name-directory claude-compose-history-file) t)
    (let ((print-length nil) (print-level nil))
      (let ((tmp (concat claude-compose-history-file ".tmp")))
        (with-temp-file tmp
          (prin1 (ring-elements ring) (current-buffer)))
        (rename-file tmp claude-compose-history-file t)))))

(defun claude-compose--browse (step)
  "Show the history entry STEP places older (negative: newer); before the newest,
the draft."
  (let* ((ring (claude-compose--load-history))
         (index (+ (or claude-compose--index -1) step)))
    (when (and (null claude-compose--index) (> step 0))
      (setq claude-compose--draft (claude-compose--input)))
    (cond ((>= index (ring-length ring)) (user-error "No older message"))
          ((< index 0) (setq claude-compose--index nil)
           (claude-compose--set-input claude-compose--draft))
          (t (setq claude-compose--index index)
             (claude-compose--set-input (ring-ref ring index))))))

(defun claude-compose-previous ()
  "Replace the text with the previous (older) sent message."
  (interactive)
  (claude-compose--browse 1))

(defun claude-compose-next ()
  "Replace the text with the next (newer) sent message, then the draft."
  (interactive)
  (unless claude-compose--index (user-error "Already at the draft"))
  (claude-compose--browse -1))

;;; Recipient: who is listening on the cal socket (`claude-cal who'), shown on the header line

(defvar-local claude-compose--who nil
  "The last answer of `claude-cal who': a plist (:role :name :emoji) or (:error
TEXT).")

(defun claude-compose--who-parse (output status)
  "Parse OUTPUT of `claude-cal who' (exit STATUS) into a plist, or (:error TEXT)."
  (let ((text (string-trim output)))
    (condition-case nil
        (if (or (eql status 0) (string-prefix-p "{" text))
            (let* ((j (json-parse-string text :object-type 'alist))
                   (who (list :role (alist-get 'role j) :name (alist-get 'name j)
                              :emoji (alist-get 'emoji j) :session (alist-get 'session j))))
              ;; An offline answer still names the role: the header says so
              (if (eq (alist-get 'online j t) :false)
                  (append (list :error (or (alist-get 'reason j) "offline")) who)
                who))
          (list :error (string-remove-prefix "claude-cal: " text)))
      (error (list :error (if (string-empty-p text) "nobody listening" text))))))

(defun claude-compose--send-button ()
  "The header line's Send button: a tap sends the draft of the window it is in."
  (propertize (homun-button "Send" 'primary #'claude-compose-send t) 'help-echo "Send (C-c C-c)"))

(defconst claude-compose--header-heights
  '((1.5 1.3 1.15 1.05 1.0 1.0) (1.2 1.1 1.05 1.0 1.0 1.0))
  "Heights of header levels 1 to 6: the desktop's, then the phone's (53 columns).")

(defun claude-compose--style ()
  "Show Markdown markup, richly styled, in this buffer only.
Headers scale by face remapping, so other Markdown buffers keep their faces."
  (setq-local markdown-hide-markup nil
              markdown-header-scaling t
              markdown-fontify-code-blocks-natively t)
  (let ((heights (nth (if (bound-and-true-p homun-layout-phone) 1 0)
                      claude-compose--header-heights)))
    (cl-loop for level from 1 to 6
             for height in heights
             do (face-remap-add-relative (intern (format "markdown-header-face-%d" level))
                                         :height height))))

(defun claude-compose--header ()
  "Header line text: the recipient, a Send button, and a failed message with its
keys."
  (concat (claude-compose--header-who)
          "  " (claude-compose--send-button)
          (claude-compose--bus-header)
          (when-let* (((claude-compose--manager-p)) (m (claude-compose--failed-any)))
            (propertize (format "  ✗ not sent: %s"
                                (plist-get m :error))
                        'face 'error))))

(defun claude-compose--header-who ()
  "The recipient, in its role colour, or the reason nobody takes the message."
  (let ((who claude-compose--who))
    (cond
     ((null who) " → …")
     ((and (plist-get who :error) (plist-get who :name))
      (propertize (format " → %s%s (offline)"
                          (if-let* ((e (plist-get who :emoji)) ((stringp e))) (concat e " ") "")
                          (plist-get who :name))
                  'face 'shadow))
     ((plist-get who :error) (propertize " → nobody listening" 'face 'error))
     (t (let* ((role (plist-get who :role))
               (style (and (stringp role) (fboundp 'claude-homun-role-style)
                           (claude-homun-role-style role)))
               (color (plist-get style :color)))
          (propertize (format " → %s%s" (if-let* ((e (plist-get who :emoji)) ((stringp e))) (concat e " ") "")
                              (plist-get who :name))
                      'face (if color `(:foreground ,color :weight bold) 'bold)))))))

(defun claude-compose--who-refresh ()
  "Ask the listener who it is, asynchronously; the header updates when it answers."
  (if (or (null (claude-compose-route-who (claude-compose--route)))
          (claude-compose--stream-dir))
      ;; No listener to ask (the Mechanic) or a headless role (its stream, not a cal socket,
      ;; is its reader): name the role from its style
      (let* ((role (symbol-name (claude-compose-route-role (claude-compose--route))))
             (style (and (fboundp 'claude-homun-role-style) (claude-homun-role-style role))))
        (setq claude-compose--who
              (append (unless (or (claude-compose--stream-dir)
                                  (claude-compose--bus-p (claude-compose--route)))
                        (list :error "no reader"))
                      (list :role role :name (or (plist-get style :name) role)
                            :emoji (plist-get style :emoji)))))
  (let ((out (generate-new-buffer " *claude-who*" t))
        (buffer (current-buffer)))
    (condition-case nil
        (make-process
         :name "claude-who" :buffer out :noquery t :connection-type 'pipe
         :command (claude-compose-route-who (claude-compose--route))
         :sentinel
         (lambda (proc _event)
           (unless (process-live-p proc)
             (let ((who (claude-compose--who-parse
                         (with-current-buffer out (buffer-string)) (process-exit-status proc))))
               (kill-buffer out)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq claude-compose--who who)
                   (force-mode-line-update)))))))
      (file-missing (kill-buffer out)
                    (setq claude-compose--who (list :error "cannot run the who command")))))))

;;; Sending over the bus

(declare-function claude-bus-reader-ok-p "claude-bus")
(declare-function claude-bus-user-write "claude-bus")
(declare-function claude-bus-user-where "claude-bus")
(declare-function claude-bus-user-dir "claude-bus")
(declare-function claude-bus-user-counts "claude-bus")
(declare-function claude-bus-user-pause "claude-bus")
(declare-function claude-bus-user-retry "claude-bus")
(declare-function claude-bus-user-drop "claude-bus")
(declare-function claude-bus-user-prune "claude-bus")
(declare-function claude-bus-roles "claude-bus")

(defvar claude-compose--bus-watches nil "Alist (ROLE . DESCRIPTORS) of the bus dirs watched.")

(defun claude-compose--bus-p (route)
  "Non-nil when ROUTE's role reads Cal's words from the bus now."
  (and (not (eq (claude-compose-route-role route) 'handoff))
       (require 'claude-bus nil t)
       (claude-bus-reader-ok-p (claude-compose-route-role route))))

(defun claude-compose--bus-changed (role)
  "Something moved in ROLE's bus dirs: update the outbox (the Manager's) and the
headers."
  (when (eq role 'manager) (claude-compose--sync))
  (force-mode-line-update t))

(defvar claude-compose--prune-timer nil "Prunes delivered messages from the watched boxes.")

(defun claude-compose--bus-watch (role)
  "Watch ROLE's box and its reader's markers (made on first use) for changes."
  (unless (assq role claude-compose--bus-watches)
    (require 'filenotify)
    (push (cons role
                (mapcar (lambda (sub)
                          (let ((dir (claude-bus-user-dir role sub)))
                            (make-directory dir t)
                            (ignore-errors (set-file-modes dir #o700))
                            (file-notify-add-watch dir '(change)
                                                   (lambda (_) (claude-compose--bus-changed role)))))
                        '(nil "sending" "claimed" "failed")))
          claude-compose--bus-watches)
    (unless (timerp claude-compose--prune-timer)
      (setq claude-compose--prune-timer
            (run-with-timer 60 60 #'claude-compose--bus-prune)))))

(defun claude-compose--bus-prune ()
  "Remove delivered messages from every watched role's box (the cockpit is its only
writer)."
  (dolist (w claude-compose--bus-watches)
    (ignore-errors (claude-bus-user-prune (car w)))))

(defun claude-compose--bus-send (route text)
  "Write TEXT for ROUTE's role on the bus; the Manager's goes into the outbox too."
  (let* ((role (claude-compose-route-role route))
         (id (claude-bus-user-write role text)))
    (claude-compose--bus-watch role)
    (if (eq role 'manager)
        (progn (plist-put (claude-compose--add id text 'pending) :bus role)
               (claude-compose--changed))
      (message "queued for %s" role))))

(defun claude-compose--bus-sync ()
  "Match the outbox messages sent over the bus to where their files are."
  (dolist (m claude-compose--outbox)
    (when-let* ((role (plist-get m :bus)))
      (pcase (claude-bus-user-where role (plist-get m :id))
        ('queued nil)
        ('sending (claude-outbox-move m 'sending))
        ('failed (claude-outbox-move m 'failed "the channel server could not deliver it"))
        (_ (when (memq (plist-get m :state) '(pending held sending)) ; claimed, or gone: delivered
             (claude-outbox-move m 'sent)))))))

(defun claude-compose--bus-header ()
  "The state of Cal's words to the box's role on the bus, or nil."
  (when-let* ((route (claude-compose--route))
              (role (claude-compose-route-role route))
              ((not (eq role 'handoff)))
              ((require 'claude-bus nil t))
              ((file-directory-p (claude-bus-user-dir role))))
    (let ((c (claude-bus-user-counts role)))
      (concat
       (if (claude-bus-reader-ok-p role) (propertize "  bus" 'face 'shadow)
         (propertize "  bus: no reader" 'face 'warning))
       (when (> (plist-get c :queued) 0) (format "  ◌ %d queued" (plist-get c :queued)))
       (when (> (plist-get c :sending) 0) (format "  … %d sending" (plist-get c :sending)))
       (when (> (plist-get c :failed) 0)
         (propertize (format "  ✗ %d failed" (plist-get c :failed)) 'face 'error))
       (when (plist-get c :paused) (propertize "  paused" 'face 'warning))))))

;;; Reference chips

(defun claude-compose--ref-here ()
  "The typed reference at point of the current buffer as (KIND . TARGET), or nil.
A stage node (text property `homun-node', a SCENE/NODE string), a board row, a
transcript entry, else the visiting file with its line."
  (cond ((get-text-property (point) 'homun-node)
         (cons "stage" (get-text-property (point) 'homun-node)))
        ((and (fboundp 'claude-board--task-at-point) (claude-board--task-at-point))
         (cons "board" (format "%s" (plist-get (claude-board--task-at-point) :id))))
        ((and (derived-mode-p 'claude-transcript-mode) (fboundp 'magit-current-section)
              (let ((v (ignore-errors (oref (magit-current-section) value))))
                (and (stringp v) (cons "transcript" v)))))
        (buffer-file-name
         (cons "file" (format "%s:%d" buffer-file-name (line-number-at-pos))))))

(defun claude-compose-ref-insert ()
  "Insert a chip for what point is on in the most recent other window."
  (interactive)
  (let* ((window (or (get-mru-window nil nil t) (user-error "No other window")))
         (ref (with-selected-window window (claude-compose--ref-here))))
    (unless ref (user-error "Nothing to refer to there"))
    (insert (propertize (format "[%s:%s]" (car ref) (cdr ref))
                        'homun-ref ref 'face 'link 'rear-nonsticky t))))

(defun claude-compose--refs (&optional beg end)
  "The chips between BEG and END (default: the buffer) as \"kind:target\" strings, in
order."
  (let (refs (pos (or beg (point-min))) (end (or end (point-max))))
    (while (< pos end)
      (let ((ref (get-text-property pos 'homun-ref))
            (next (next-single-property-change pos 'homun-ref nil end)))
        (when ref (push (format "%s:%s" (car ref) (cdr ref)) refs))
        (setq pos next)))
    (nreverse refs)))

(defun claude-compose--wire (text refs)
  "TEXT as the cal channel reads it: with REFS a JSON envelope whose `ref'
attribute lists them."
  (if (null refs)
      text
    (json-serialize `((meta . ((ref . ,(string-join refs ",")))) (text . ,text)))))

;;; Sending

(defun claude-compose--stream-dir ()
  "The stream directory of the box's role when it runs headless, else nil."
  (let* ((role (symbol-name (claude-compose-route-role (claude-compose--route))))
         (base (expand-file-name (concat "~/claude/.services/" role "/")))
         (mode (expand-file-name "session-mode" base)))
    (and (file-readable-p mode)
         (equal "headless" (string-trim (with-temp-buffer (insert-file-contents mode) (buffer-string))))
         (file-exists-p (expand-file-name "stream/in" base))
         (expand-file-name "stream" base))))

(defun claude-compose--stream-turn (text)
  "TEXT as Cal's words, marked as the cal channel marks them."
  (format "<channel source=\"cal\" ts=\"%s\">%s</channel>"
          (format-time-string "%FT%T%z") text))

(defun claude-compose--send-direct (text &optional stream)
  "Send TEXT through the box's route at once (the Mechanic's), or onto STREAM, a
headless role's stream directory; on a refusal show it and put TEXT back in an
empty box."
  (let* ((buffer (current-buffer))
         (name (or (plist-get claude-compose--who :name) "the session"))
         ;; The Manager's words show in its transcript as sending, then sent, until it logs them
         (item (and (claude-compose--manager-p)
                    (prog1 (claude-compose--add (format-time-string "%s%N") text 'sending)
                      (claude-compose--changed)))))
    (funcall
     (if stream
         (lambda (text done)
           (claude-agent-stream-send
            stream (claude-agent-stream-user-turn (claude-compose--stream-turn text)) done))
       (lambda (text done)
         (claude-compose--start (claude-compose-route-send (claude-compose--route)) text done)))
     text
     (lambda (error)
       (when item (claude-compose--settle item error))
       (if (null error)
           (message "sent to %s" name)
         (message "Not sent to %s: %s" name error)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (string-blank-p (claude-compose--input))
               (claude-compose--set-input text)))))))))

;; A send puts every window on the sender's transcript at the end; the transcript's own
;; follow logic (`claude-transcript--keeping-windows') then keeps them there.
(defun claude-compose--stick-transcripts ()
  "Jump the windows showing the current route's transcript to its end."
  (let ((route (claude-compose--route)))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (derived-mode-p 'claude-transcript-mode)
                   (get-buffer-window buffer t)
                   (eq route (claude-compose--route-for-file claude-transcript--file)))
          (claude-transcript-goto-end))))))

(defun claude-compose-send ()
  "Send the text: onto the stream FIFO of a headless role (the Manager's too: its
claude reads no bus nor outbox then), else over the bus when the role reads it
there, else the fallback: to the manager through the outbox (never waits), to
the Mechanic at once."
  (interactive)
  (let ((text (string-trim (claude-compose--input))))
    (when (string-empty-p text) (user-error "Nothing to send"))
    (cond ((claude-compose--stream-dir)
           (claude-compose--send-direct text (claude-compose--stream-dir)))
          ((claude-compose--bus-p (claude-compose--route))
           (claude-compose--bus-send (claude-compose--route) text))
          ((claude-compose--manager-p)
           (claude-compose--enqueue (claude-compose--wire text (claude-compose--refs))))
          ((claude-compose-route-send (claude-compose--route))
           (claude-compose--send-direct text))
          (t (user-error "%s reads no messages now (no bus/%s/reader-ok)"
                         (claude-compose-route-role (claude-compose--route))
                         (claude-compose-route-role (claude-compose--route)))))
    (claude-compose--remember text)
    (claude-compose--stick-transcripts)
    (claude-compose--set-input "")
    (setq claude-compose--index nil)
    (claude-compose--who-refresh)))

(defun claude-compose-cancel ()
  "Close the compose window; the draft stays."
  (interactive)
  (quit-window))

;;; Mode

(defvar-keymap claude-compose-mode-map
  "C-c C-c" #'claude-compose-send
  "C-c C-k" #'claude-compose-cancel
  "C-c C-r" #'claude-compose-retry
  "C-c C-d" #'claude-compose-drop
  "M-RET" #'claude-compose-ref-insert
  "M-p" #'claude-compose-previous
  "M-n" #'claude-compose-next
  "C-c ?" #'homun-menu-compose)

(define-minor-mode claude-compose-mode
  "C-c C-c sends to the manager, C-c C-k closes (keeps the draft), M-p/M-n browse
history, C-c C-r retries a failed message, C-c C-d drops it."
  :lighter " Compose" :keymap claude-compose-mode-map)

(with-eval-after-load 'evil
  (evil-define-minor-mode-key '(normal insert) 'claude-compose-mode
    (kbd "C-c C-c") #'claude-compose-send
    (kbd "C-c C-k") #'claude-compose-cancel
    (kbd "C-c C-r") #'claude-compose-retry
    (kbd "C-c C-d") #'claude-compose-drop
    (kbd "M-RET") #'claude-compose-ref-insert
    (kbd "M-p") #'claude-compose-previous
    (kbd "M-n") #'claude-compose-next)
  ;; Doom's edit-buffer convention
  (evil-define-minor-mode-key 'normal 'claude-compose-mode
    (kbd "ZZ") #'claude-compose-send
    (kbd "ZQ") #'claude-compose-cancel
    (kbd "TAB") #'homun-layout-focus-toggle))

(defun claude-compose--buffer (&optional route)
  "The compose buffer of ROUTE (default: the Manager's), set up on first use."
  (let ((route (or route (claude-compose-route 'manager))))
    (or (get-buffer (claude-compose-route-buffer route))
      (with-current-buffer (get-buffer-create (claude-compose-route-buffer route))
        (cond ((fboundp 'gfm-mode) (gfm-mode))
              ((fboundp 'markdown-mode) (markdown-mode))
              (t (text-mode)))
        (claude-compose-mode)
        ;; After the major mode: it kills buffer-local variables
        (setq claude-compose--route route)
        (claude-compose--style)
        (setq-local header-line-format '(:eval (claude-compose--header)))
        (when (executable-find "aspell")
          (setq-local ispell-program-name "aspell")
          ;; Flyspell's default waits with `sit-for' after each typed word, inside the command
          ;; loop: a timer does the same check without blocking
          (setq-local flyspell-delay-use-timer t)
          (flyspell-mode 1))
        (current-buffer)))))

(defun claude-compose--show (&optional route)
  "Show the compose box of ROUTE (default: the Manager's) in the bottom side
window, slot 0, replacing the box there; enter it.  Never in the main area,
whatever action the caller bound."
  (let* ((buffer (claude-compose--buffer route))
         (window (homun-layout-place buffer t)))
    (with-current-buffer buffer
      (claude-compose--who-refresh)
      ;; In the box only: when it could not be shown, the current buffer is another one
      (when (and window (fboundp 'evil-insert-state)) (evil-insert-state)))
    window))

;;;###autoload
(defun claude-compose ()
  "Compose a Markdown message to the manager's main session in a split below.
In an agent's transcript this refuses: only the main session takes messages."
  (interactive)
  (cond
   ((derived-mode-p 'claude-transcript-mode)
    (claude-compose--show
     (or (claude-compose--route-for-file claude-transcript--file)
         (user-error "This is an agent transcript: read-only, only a role's main session takes messages"))))
   ((derived-mode-p 'claude-board-mode)
    (unless (eq (plist-get (claude-board--task) :kind) 'main)
      (user-error "Only a role's main row takes messages"))
    (claude-board-open))
   (t
    ;; A box shows only beside its transcript (`claude-compose--pair'): open that first
    (let ((file (claude-compose--main-file)))
      (unless (or (null file)
                  (assoc (claude-compose-route-buffer (claude-compose-route 'manager))
                         (claude-compose--visible-routes (selected-frame))))
        (claude-transcript-open file)))
    (claude-compose--show))))

;;;###autoload
(defun claude-compose-to (role)
  "Compose a message to ROLE (any role on the bus, or the Manager or Mechanic's
fallback)."
  (interactive
   (list (intern (completing-read
                  "Message to: "
                  (delete-dups (append '("manager" "mechanic")
                                       (and (require 'claude-bus nil t)
                                            (remove "user" (claude-bus-roles)))))
                  nil t))))
  ;; The phone composes in its own buffer, to `claude-remote-home-role'
  (when (boundp 'claude-remote-home-role)
    (setq claude-remote-home-role (symbol-name role)))
  (claude-compose--follow-transcript role)
  (claude-compose--show (claude-compose-route role)))

(defun claude-compose--follow-transcript (role)
  "Switch the windows showing a transcript to ROLE's main session; other buffers
stay put.
Nothing changes when ROLE has no readable transcript."
  (when-let* ((windows (seq-filter (lambda (w)
                                     (with-current-buffer (window-buffer w)
                                       (derived-mode-p 'claude-transcript-mode)))
                                   (window-list)))
              (file (ignore-errors (claude-board--role-file role claude-board-main-dir)))
              ((file-readable-p file)))
    (let ((buffer (claude-transcript-buffer file)))
      (dolist (w windows) (set-window-buffer w buffer)))))

;;; A box is visible only while its transcript is

(defvar claude-compose--pairing nil "Non-nil while `claude-compose--pair' changes windows.")
(defvar claude-compose--pair-timer nil)

(defun claude-compose--visible-routes (frame)
  "The routes of the main transcripts the windows of FRAME show, one per box."
  (let (routes)
    (dolist (window (window-list frame 'no-minibuf))
      (with-current-buffer (window-buffer window)
        ;; The focus view reads a transcript too: its box stays
        (when-let* ((file (cond ((derived-mode-p 'claude-transcript-mode)
                                 (bound-and-true-p claude-transcript--file))
                                ((derived-mode-p 'claude-transcript-focus-mode)
                                 (bound-and-true-p claude-transcript-focus--file))))
                    (route (ignore-errors (claude-compose--route-for-file file))))
          (unless (assoc (claude-compose-route-buffer route) routes)
            (push (cons (claude-compose-route-buffer route) route) routes)))))
    (nreverse routes)))

(defun claude-compose--box-p (window)
  "Non-nil when WINDOW shows a compose box."
  (with-current-buffer (window-buffer window)
    (and (bound-and-true-p claude-compose-mode) claude-compose--route t)))

(defun claude-compose--hide (window)
  "Take the compose box out of WINDOW: a layout slot goes blank, any other window
closes."
  (homun-layout-close window))

(defun claude-compose--pair-frame (frame)
  "In FRAME, close each box whose transcript is not shown, and with
`claude-compose-auto-open' show the box of a transcript that just appeared."
  (let* ((routes (claude-compose--visible-routes frame))
         (before (frame-parameter frame 'claude-compose-boxes))
         (boxes nil))
    (dolist (window (window-list frame 'no-minibuf))
      (when (claude-compose--box-p window)
        (let ((name (buffer-name (window-buffer window))))
          (if (assoc name routes)
              (push name boxes)
            (claude-compose--hide window)))))
    (set-frame-parameter frame 'claude-compose-boxes (mapcar #'car routes))
    (when claude-compose-auto-open
      (pcase-dolist (`(,name . ,route) routes)
        (unless (or (member name boxes) (member name before))
          (with-selected-frame frame
            (save-selected-window (claude-compose--show route))))))))

(defun claude-compose--pair ()
  "Pair the compose boxes of every frame with the transcripts it shows."
  (setq claude-compose--pair-timer nil)
  (unless claude-compose--pairing
    (let ((claude-compose--pairing t))
      (dolist (frame (frame-list))
        (when (frame-live-p frame)
          (ignore-errors (claude-compose--pair-frame frame)))))))

(defun claude-compose--pair-soon (&rest _)
  "Run `claude-compose--pair' once the command that changed a window is over."
  (unless (or claude-compose--pairing (timerp claude-compose--pair-timer))
    (setq claude-compose--pair-timer (run-with-timer 0 nil #'claude-compose--pair))))

(add-hook 'window-buffer-change-functions #'claude-compose--pair-soon)

(defun claude-compose--auto (file &rest _)
  "After `claude-transcript-open' of a role's main session FILE: show that role's
box."
  (when claude-compose-auto-open
    (when-let* ((route (claude-compose--route-for-file file)))
      (claude-compose--show route))))

(advice-add 'claude-transcript-open :after #'claude-compose--auto)

;;; Keys: C-c m in the transcript and the board, SPC m c with Doom's local leader

(defun claude-compose--bind (feature map)
  "Bind `claude-compose' in MAP of FEATURE once it is loaded."
  (with-eval-after-load feature
    (define-key (symbol-value map) (kbd "C-c m") #'claude-compose)
    (when (fboundp 'map!)
      (eval `(map! :localleader :map ,map "c" #'claude-compose) t))))

(claude-compose--bind 'claude-transcript 'claude-transcript-mode-map)
(claude-compose--bind 'claude-board 'claude-board-mode-map)

(ignore-errors (claude-compose--recover))
(ignore-errors (claude-compose--queue-watch))
(ignore-errors (claude-compose--sync))
(ignore-errors (claude-compose--status-start))
(ignore-errors (claude-compose--claim-timer))
(ignore-errors
  (when (and (require 'claude-bus nil t) (file-directory-p (claude-bus-user-dir 'manager)))
    (claude-compose--bus-watch 'manager)))

(provide 'claude-compose)
;;; claude-compose.el ends here
