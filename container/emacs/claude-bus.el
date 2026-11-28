;;; claude-bus.el --- The cockpit's side of the message bus -*- lexical-binding: t -*-

;; The bus is a directory per recipient under ~/claude/.services/bus/ (stage 5):
;;
;;   bus/<to>/inbox.jsonl         one JSON line {id,ts,from,to,alarm,msg,via?} per message,
;;                                appended by homun-msg; rotated at 1 MiB
;;   bus/<to>/cursors/<reader>    "INODE POS": how far a reader got
;;   bus/<role>/reader-ok         touched by the role's channel server while it reads
;;   bus/<role>/user/<device>/<ns> Cal's words to ROLE (Markdown), read-only to every role
;;   bus/<role>/user-state/<device>/{sending,claimed,failed}/<ns>
;;                                the role's reader marks each message there (O_EXCL into
;;                                sending/, then claimed/ or failed/); a `paused' file there
;;                                holds the queue.  A message without a marker is queued.
;;                                The cockpit prunes claimed messages from the box, then
;;                                their markers (`claude-bus-user-prune').
;;
;; `claude-bus-tail' follows an inbox like a stream tail, but in
;; this Emacs: a file-notify watch on the directory and a byte cursor, so a change reads
;; only the bytes appended since, and nothing runs between changes.  Directories are made
;; on first use.
;;
;; A remote cockpit (claude-remote.el) sets `claude-bus-transport': tails, sends and the
;; user's words then go through the cockpit gateway instead of these files.

(require 'cl-lib)
(require 'homun-proc)
(require 'filenotify)
(require 'subr-x)

(defvar claude-bus-dir (expand-file-name "~/claude/.services/bus/")
  "The root of the bus.")

(defvar claude-bus-reader "cockpit" "This Emacs's name in the cursors/ directories.")

(defvar claude-bus-device "host" "The device directory Cal's words from this Emacs go to.")

(defvar claude-bus-reader-ok-max 120
  "Seconds after which a role's reader-ok heartbeat counts as missing.")

(defvar claude-bus-transport nil
  "nil: the bus is the files under `claude-bus-dir'.  Else a plist of functions
that stand in for them: :tail (FILE HANDLER) returning a handle,
:untail (HANDLE), :send (TO ALARM MSG) returning an id, :user-write (ROLE TEXT)
returning an id, :reader-ok (ROLE) and :roles () returning the recipients.")

(defun claude-bus--via (key &rest args)
  "Call the transport's KEY with ARGS when a transport is set and has it; else
`:none'."
  (if-let* ((fn (plist-get claude-bus-transport key))) (apply fn args) :none))

(defun claude-bus-path (&rest parts)
  "The file PARTS under `claude-bus-dir'."
  (let ((path (file-name-as-directory claude-bus-dir)))
    (dolist (part parts path)
      (setq path (expand-file-name part (file-name-as-directory path))))))

(defun claude-bus--mkdir (dir)
  "Make DIR (mode 700) when it is missing; return it."
  (unless (file-directory-p dir)
    (make-directory dir t)
    (ignore-errors (set-file-modes dir #o700)))
  dir)

(defun claude-bus--write-atomic (file text)
  "Write TEXT to FILE through a temp file beside it and a rename."
  (let ((tmp (make-temp-file (expand-file-name ".tmp" (claude-bus--mkdir (file-name-directory file)))))
        (coding-system-for-write 'utf-8-unix))
    (write-region text nil tmp nil 'silent)
    (rename-file tmp file t)
    file))

;;; Reading an inbox

(cl-defstruct (claude-bus-tail (:constructor claude-bus-tail--make))
  file handler cursor inode (pos 0) watch)

(defun claude-bus--cursor-file (tail)
  (when-let* ((name (claude-bus-tail-cursor tail)))
    (expand-file-name (concat "cursors/" name) (file-name-directory (claude-bus-tail-file tail)))))

(defun claude-bus--cursor-load (tail)
  "(INODE . POS) saved for TAIL, or nil."
  (when-let* ((file (claude-bus--cursor-file tail))
              (text (ignore-errors (with-temp-buffer (insert-file-contents file) (buffer-string))))
              (words (split-string text)))
    (when (= (length words) 2)
      (cons (string-to-number (car words)) (string-to-number (cadr words))))))

(defun claude-bus--cursor-save (tail)
  (when-let* ((file (claude-bus--cursor-file tail)))
    (ignore-errors
      (claude-bus--write-atomic file (format "%s %d\n" (claude-bus-tail-inode tail)
                                             (claude-bus-tail-pos tail))))))

(defun claude-bus-parse (line)
  "The message of the JSON LINE as a plist, or nil."
  (ignore-errors (json-parse-string line :object-type 'plist :null-object nil :false-object nil)))

(defun claude-bus--read (tail)
  "Hand TAIL's handler each complete line appended since its cursor; return their
count."
  (let* ((file (claude-bus-tail-file tail))
         (attrs (file-attributes file))
         (size (or (file-attribute-size attrs) 0))
         (inode (file-attribute-inode-number attrs))
         (pos (claude-bus-tail-pos tail))
         (count 0))
    ;; A rotation gives a new file: start it at 0
    (when (or (< size pos) (and inode (claude-bus-tail-inode tail)
                                (not (equal inode (claude-bus-tail-inode tail)))))
      (setq pos 0))
    (setf (claude-bus-tail-inode tail) inode)
    (when (> size pos)
      (let (lines)
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert-file-contents-literally file nil pos size)
          (goto-char (point-max))
          (when (search-backward "\n" nil t)
            (setq lines (split-string (decode-coding-string
                                       (buffer-substring (point-min) (point)) 'utf-8)
                                      "\n" t)
                  pos (+ pos (point)))))
        (setf (claude-bus-tail-pos tail) pos)
        (dolist (line lines)
          (when-let* ((m (claude-bus-parse line)))
            (cl-incf count)
            (with-demoted-errors "claude-bus: %S"
              (funcall (claude-bus-tail-handler tail) m))))
        (when lines (claude-bus--cursor-save tail))))
    (setf (claude-bus-tail-pos tail) pos)
    count))

(defun claude-bus--start-pos (file backlog)
  "Where a reader without a cursor starts in FILE: BACKLOG bytes before its end, at
a line."
  (let ((size (or (file-attribute-size (file-attributes file)) 0)))
    (if (or (null backlog) (<= size backlog))
        (if backlog 0 size)
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file nil (- size backlog) size)
        (goto-char (point-min))
        (+ (- size backlog) (if (search-forward "\n" nil t) (1- (point)) (buffer-size)))))))

(cl-defun claude-bus-tail (file handler &key cursor backlog)
  "Follow the inbox FILE, calling HANDLER with each new message, a plist.
CURSOR names a reader whose position is kept in cursors/CURSOR beside FILE, so a
restart goes on where it stopped.  Without a saved position the reading starts
BACKLOG bytes before the end (nil: at the end).  Returns the tail;
`claude-bus-untail' stops it."
  (let ((remote (claude-bus--via :tail (expand-file-name file) handler)))
    (if (not (eq remote :none)) remote
      (claude-bus--tail-file (expand-file-name file) handler cursor backlog))))

(defun claude-bus--tail-file (file handler cursor backlog)
  "`claude-bus-tail' on the local FILE."
  (let* ((tail (claude-bus-tail--make :file file :handler handler :cursor cursor))
         (saved (claude-bus--cursor-load tail))
         (inode (file-attribute-inode-number (file-attributes file))))
    (claude-bus--mkdir (file-name-directory file))
    (if (and saved (equal (car saved) inode))
        (setf (claude-bus-tail-pos tail) (cdr saved) (claude-bus-tail-inode tail) inode)
      (setf (claude-bus-tail-pos tail) (claude-bus--start-pos file backlog)
            (claude-bus-tail-inode tail) inode))
    (setf (claude-bus-tail-watch tail)
          (file-notify-add-watch (file-name-directory file) '(change)
                                 (lambda (event)
                                   (when (equal (file-name-nondirectory (or (nth 2 event) ""))
                                                (file-name-nondirectory file))
                                     (claude-bus--read tail)))))
    (claude-bus--read tail)
    tail))

(defun claude-bus-untail (tail)
  "Stop following TAIL."
  (unless (claude-bus-tail-p tail) (claude-bus--via :untail tail))
  (when (and (claude-bus-tail-p tail) (claude-bus-tail-watch tail))
    (ignore-errors (file-notify-rm-watch (claude-bus-tail-watch tail)))
    (setf (claude-bus-tail-watch tail) nil)))

(defun claude-bus-roles ()
  "The recipients with a directory on the bus, as strings (`user' too)."
  (let ((remote (claude-bus--via :roles)))
    (if (not (eq remote :none)) remote
      (and (file-directory-p claude-bus-dir)
       (seq-filter (lambda (name) (file-directory-p (claude-bus-path name)))
                   (directory-files claude-bus-dir nil "\\`[a-z][a-z0-9_-]*\\'"))))))

;;; Sending an alarm

(defun claude-bus-send (to alarm msg)
  "Put the message ALARM with text MSG into TO's inbox, from Cal; return its id.
Through homun-msg when it is on PATH (it locks and rotates), else an append of
one line, which the kernel does in one write while it stays under 4 KiB."
  (let ((to (format "%s" to))
        (remote (claude-bus--via :send (format "%s" to) alarm msg)))
    (cond
     ((not (eq remote :none)) remote)
     ((executable-find "homun-msg")
        (let ((r (homun-proc-sync "homun-msg" (list "send" to alarm msg))))
          (unless (eql 0 (car r)) (error "homun-msg: %s" (string-trim (cdr r))))
          (string-trim (cdr r))))
     (t
      (let* ((id (format-time-string "%s%N"))
             (line (concat (json-serialize (list :id id :ts (floor (float-time)) :from "user"
                                                 :to to :alarm alarm :msg msg))
                           "\n"))
             (file (claude-bus-path to "inbox.jsonl"))
             (coding-system-for-write 'utf-8-unix))
        (claude-bus--mkdir (file-name-directory file))
        (write-region line nil file t 'silent)
        id)))))

(defun claude-bus-tell (to alarm msg old-file)
  "Send ALARM with MSG to TO over the bus while its reader runs, else append it to
OLD-FILE
\(the scheduler events of before the bus), never both."
  (if (claude-bus-reader-ok-p to)
      (claude-bus-send to alarm msg)
    (append-to-file (concat (json-serialize `(:ts ,(floor (float-time)) :alarm ,alarm :msg ,msg)) "\n")
                    nil old-file)))

;;; Cal's words to a role

(defun claude-bus-reader-ok-p (role)
  "Non-nil when ROLE's channel server has touched bus/ROLE/reader-ok lately."
  (let ((remote (claude-bus--via :reader-ok role)))
    (if (not (eq remote :none)) remote
      (claude-bus--reader-ok-file role))))

(defun claude-bus--reader-ok-file (role)
  "`claude-bus-reader-ok-p' from the local heartbeat file."
  (when-let* ((attrs (file-attributes (claude-bus-path (format "%s" role) "reader-ok"))))
    (< (- (float-time) (float-time (file-attribute-modification-time attrs)))
       claude-bus-reader-ok-max)))

(defun claude-bus-user-dir (role &optional sub)
  "Cal's box for ROLE on this device (read-only to the role), or its state's SUB.
SUB is `sending', `claimed' or `failed', the role's markers in
bus/ROLE/user-state/, or \"\" for that state directory itself."
  (if sub
      (apply #'claude-bus-path (format "%s" role) "user-state" claude-bus-device
             (unless (equal sub "") (list sub)))
    (claude-bus-path (format "%s" role) "user" claude-bus-device)))

(defun claude-bus-user-write (role text)
  "Queue TEXT for ROLE as a new file; return its name (nanoseconds since the
epoch).
With a transport, the transport sends it (and may keep the file while it waits)."
  (let ((remote (claude-bus--via :user-write role text)))
    (if (not (eq remote :none)) remote
      (let ((id (format-time-string "%s%N")))
        (claude-bus--write-atomic (expand-file-name id (claude-bus-user-dir role)) text)
        id))))

(defun claude-bus--user-files (dir)
  "The message names in DIR, oldest first."
  (and (file-directory-p dir) (directory-files dir nil "\\`[0-9]+\\'")))

(defun claude-bus--user-marked (role id)
  "The marker ROLE's reader left for message ID: `sending', `claimed', `failed' or
nil."
  (seq-find (lambda (kind) (file-exists-p (expand-file-name id (claude-bus-user-dir role (symbol-name kind)))))
            '(failed claimed sending)))

(defun claude-bus-user-names (role &optional sub)
  "The messages for ROLE still queued (no marker), oldest first; with SUB, its
markers."
  (if sub (claude-bus--user-files (claude-bus-user-dir role sub))
    (seq-remove (lambda (id) (claude-bus--user-marked role id))
                (claude-bus--user-files (claude-bus-user-dir role)))))

(defun claude-bus-user-where (role id)
  "Where message ID to ROLE is: `queued', `sending', `claimed', `failed', or
nil (gone)."
  (or (claude-bus--user-marked role id)
      (and (file-exists-p (expand-file-name id (claude-bus-user-dir role))) 'queued)))

(defun claude-bus-user-counts (role)
  "(:queued N :sending N :failed N :paused BOOL) of Cal's words to ROLE."
  (list :queued (length (claude-bus-user-names role))
        :sending (length (claude-bus-user-names role "sending"))
        :failed (length (claude-bus-user-names role "failed"))
        :paused (file-exists-p (expand-file-name "paused" (claude-bus-user-dir role "")))))

(defun claude-bus-user-pause (role on)
  "Hold ROLE's queue (ON non-nil) or let it go again."
  (let ((file (expand-file-name "paused" (claude-bus-user-dir role ""))))
    (cond ((and on (not (file-exists-p file)))
           (claude-bus--mkdir (file-name-directory file))
           (write-region "" nil file nil 'silent))
          ((and (not on) (file-exists-p file)) (ignore-errors (delete-file file))))))

(defun claude-bus-user-retry (role id)
  "Queue the failed message ID to ROLE again: drop its failed marker."
  (delete-file (expand-file-name id (claude-bus-user-dir role "failed"))))

(defun claude-bus-user-drop (role id)
  "Delete message ID to ROLE, then its markers (in that order, so it is never
pending again)."
  (dolist (sub '(nil "sending" "failed" "claimed"))
    (ignore-errors (delete-file (expand-file-name id (claude-bus-user-dir role sub))))))

(defun claude-bus-user-withdraw (role id)
  "Take back the queued message ID to ROLE before its reader claims it.
Return t when it was withdrawn (its file is gone, no marker), `claimed' when the
reader marked it first (the file stays), nil when it is gone already.  The
marker is looked at again after the delete: a claim that raced it reports
`claimed'."
  (let ((file (expand-file-name id (claude-bus-user-dir role))))
    (cond ((claude-bus--user-marked role id) 'claimed)
          ((not (file-exists-p file)) nil)
          (t (delete-file file)
             (if (claude-bus--user-marked role id) 'claimed t)))))

(defvar claude-bus-user-keep 60
  "Seconds a claimed message stays in the box before `claude-bus-user-prune'
removes it.")

(defun claude-bus-user-prune (role)
  "Remove ROLE's messages claimed over `claude-bus-user-keep' seconds ago, then
their markers."
  (let ((now (float-time)))
    (dolist (id (claude-bus-user-names role "claimed"))
      (let* ((marker (expand-file-name id (claude-bus-user-dir role "claimed")))
             (attrs (file-attributes marker)))
        (when (and attrs (> (- now (float-time (file-attribute-modification-time attrs)))
                            claude-bus-user-keep))
          (ignore-errors (delete-file (expand-file-name id (claude-bus-user-dir role))))
          (unless (file-exists-p (expand-file-name id (claude-bus-user-dir role)))
            (ignore-errors (delete-file marker))))))))

(provide 'claude-bus)
;;; claude-bus.el ends here
