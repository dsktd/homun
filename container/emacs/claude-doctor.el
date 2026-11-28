;;; claude-doctor.el --- The health of everything Homun runs, as a Stage scene -*- coding: utf-8; lexical-binding: t -*-

;; The scene `doctor' (lifetime system) lists the role rows of `homun-doctor json'
;; (container/homun-doctor): one per role session (the manager's channel, the mechanic, every
;; broker session) with a status dot, its key facts and, when it is not ok, one line of what to
;; do.  The CLI and the API entry `doctor get' still carry every check; the scene only draws
;; these.  While a window shows it, it asks again every `claude-doctor-interval' seconds; the
;; timer ends itself when the scene is closed or hidden and starts again when it is shown.
;;
;; Open on a row shows the log or state file behind it (its tail, read-only) or the buffer it
;; names.  Restarting a service is a hold button: on the row of a service that is not ok, and
;; on the mechanic's.  The cockpit's container cannot restart a service of the manager's, so
;; the restart is a `service' request to the host service (bin/homun-host).
;;
;; The daemon's own facts (`claude-doctor-probe') go to the script in $HOMUN_DOCTOR_COCKPIT;
;; any other caller gets them through the API entry `doctor probe'.  *Messages* has no
;; times, so error lines are counted when they are first seen, at a probe: the count of the
;; last hour is exact while the scene is shown and an upper bound after a quiet spell.

;;; Code:

(require 'homun-dir)
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'homun-layout)
(require 'homun-stage-store)

(defconst claude-doctor-scene "doctor" "The id of the doctor scene on the Stage.")

(defvar claude-doctor-command
  (list "nu" (expand-file-name "../homun-doctor"
                               homun-cockpit-dir)
        "json")
  "The command that prints the checks as JSON.")

(defvar claude-doctor-interval 10 "Seconds between two looks while the scene is shown.")

(defvar claude-doctor-role-ids '("scheduler.channel" "mechanic.heartbeat")
  "Ids of the checks that are a role's session; every `broker.*' check is one too.")

(defvar claude-doctor-host-dir (expand-file-name "~/claude/.services/host/")
  "The host service's directory: its request spool and its answers.")

(defvar claude-doctor-error-regexp
  "\\(?:\\b[Ee]rror\\b\\|wrong-type-argument\\|void-function\\|void-variable\\|args-out-of-range\\)"
  "What makes a line of *Messages* an error line.")

(defvar claude-doctor--data nil "The last answer of the command, an alist, or nil.")
(defvar claude-doctor--problem nil "Why the last run gave no answer, or nil.")
(defvar claude-doctor--process nil)
(defvar claude-doctor--timer nil)

(defconst claude-doctor-dots '(("ok" . "ok") ("warn" . "warn") ("fail" . "err"))
  "Each status with the scene face of its dot; any other status is dim.")

;;; The daemon about itself

(defvar claude-doctor--mark nil "Marker in *Messages*: everything before it was looked at.")
(defvar claude-doctor--errors nil "Error lines seen in *Messages*, newest first: (TIME . LINE).")

(defun claude-doctor--scan-messages ()
  "Note the error lines *Messages* got since the last look; the first look only
sets the mark."
  (with-current-buffer (messages-buffer)
    (if (not (and (markerp claude-doctor--mark) (eq (marker-buffer claude-doctor--mark) (current-buffer))))
        (setq claude-doctor--mark (copy-marker (point-max)))
      (save-excursion
        (goto-char claude-doctor--mark)
        (let ((case-fold-search nil))
          (while (re-search-forward claude-doctor-error-regexp nil t)
            (push (cons (float-time)
                        (buffer-substring-no-properties (line-beginning-position) (line-end-position)))
                  claude-doctor--errors)
            (forward-line 1))))
      (set-marker claude-doctor--mark (point-max))))
  (let ((since (- (float-time) 3600)))
    (setq claude-doctor--errors
          (seq-take (seq-filter (lambda (e) (> (car e) since)) claude-doctor--errors) 500))))

;;; The transcripts the cockpit follows

(defvar claude-board-role-dirs)
(declare-function claude-board--role-file "claude-board")
(defvar claude-transcript--file)
(defvar claude-transcript--offset)
(defvar claude-transcript--watch)

(defun claude-doctor--transcript (role dir)
  "How the cockpit follows ROLE's session under DIR: an alist for `json-serialize'.
file is the transcript (or none), age_s its last write, open whether a buffer
shows it, following whether that buffer watches it, behind whether the buffer
read less than the file has."
  (let* ((file (ignore-errors (claude-board--role-file role dir)))
         (size (and file (file-attribute-size (file-attributes file))))
         (buffer (and file (seq-find (lambda (b)
                                       (with-current-buffer b
                                         (and (derived-mode-p 'claude-transcript-mode)
                                              claude-transcript--file
                                              (file-equal-p claude-transcript--file file))))
                                     (buffer-list)))))
    `((role . ,(symbol-name role)) (file . ,(or file :null))
      (age_s . ,(if file (floor (float-time (time-since (file-attribute-modification-time (file-attributes file))))) :null))
      (open . ,(if buffer t :false))
      (following . ,(if (and buffer (buffer-local-value 'claude-transcript--watch buffer)) t :false))
      (behind . ,(if (and buffer size (< (or (buffer-local-value 'claude-transcript--offset buffer) 0) size)) t :false)))))

(defun claude-doctor--transcripts ()
  (require 'claude-board)
  (vconcat (mapcar (lambda (e) (claude-doctor--transcript (car e) (cdr e))) claude-board-role-dirs)))

(defun claude-doctor-probe ()
  "What the daemon says about itself, an alist for `json-serialize'."
  (claude-doctor--scan-messages)
  `((pid . ,(emacs-pid)) (version . ,emacs-version)
    (uptime_s . ,(floor (float-time (time-since before-init-time))))
    (frames . ,(length (frame-list))) (buffers . ,(length (buffer-list)))
    (transcripts . ,(claude-doctor--transcripts))
    (errors_1h . ,(length claude-doctor--errors))
    (errwatch_1h . ,(if (fboundp 'claude-errwatch-count-1h) (claude-errwatch-count-1h) :null))
    (errwatch_failed . ,(if (fboundp 'claude-errwatch-failed-count) (claude-errwatch-failed-count) :null))
    (portal . ,(condition-case nil (progn (require 'dbus) (and (dbus-get-unique-name :session) t))
                 (error :false)))
    (freeze_watch . ,(if (bound-and-true-p homun-freeze-watch-mode) t :false))
    (freeze_gaps_1h . ,(if (fboundp 'homun-freeze-watch-count) (homun-freeze-watch-count 1.0 3600) :null))
    (last_error . ,(truncate-string-to-width (or (cdar claude-doctor--errors) "") 200))))

;;; Running the command

(defun claude-doctor--environment ()
  (cons (concat "HOMUN_DOCTOR_COCKPIT=" (json-serialize (claude-doctor-probe)))
        process-environment))

(defun claude-doctor--parse (text)
  "The command's answer TEXT as an alist; signals when it does not read."
  (json-parse-string text :object-type 'alist :array-type 'list :null-object nil :false-object nil))

(defun claude-doctor-run ()
  "Run the command now and wait for it; return its answer as an alist."
  (with-temp-buffer
    (let ((process-environment (claude-doctor--environment)))
      (apply #'call-process (car claude-doctor-command) nil '(t nil) nil (cdr claude-doctor-command)))
    (claude-doctor--parse (buffer-string))))

(defun claude-doctor--stderr-line (process)
  "The first line the command of PROCESS wrote to stderr, or nil."
  (when-let* ((file (process-get process 'stderr-file))
              ((file-readable-p file))
              (text (string-trim (with-temp-buffer (insert-file-contents file) (buffer-string))))
              ((not (string-empty-p text))))
    (car (split-string text "\n"))))

(defun claude-doctor--drop-stderr (process)
  (when-let* ((file (process-get process 'stderr-file))) (ignore-errors (delete-file file))))

(defun claude-doctor--done (process _event)
  "Sentinel: take the answer of PROCESS and draw it."
  (unless (process-live-p process)
    (let ((out (process-buffer process)))
      (condition-case err
          (setq claude-doctor--data (claude-doctor--parse (with-current-buffer out (buffer-string)))
                claude-doctor--problem nil)
        (error (setq claude-doctor--problem
                     (format "the checks did not run (exit %s): %s%s" (process-exit-status process)
                             (error-message-string err)
                             (let ((why (claude-doctor--stderr-line process)))
                               (if why (concat ": " why) ""))))))
      (claude-doctor--drop-stderr process)
      (when (buffer-live-p out) (kill-buffer out))
      (claude-doctor--show-scene))))

(defun claude-doctor-refresh ()
  "Ask for the checks again, in the background; the scene is drawn when they
arrive."
  (interactive)
  (unless (process-live-p claude-doctor--process)
    (let ((process-environment (claude-doctor--environment))
          (errors (make-temp-file "homun-doctor-err")))
      (setq claude-doctor--process
            (make-process :name "homun-doctor" :noquery t :connection-type 'pipe
                          :buffer (generate-new-buffer " *homun-doctor-out*")
                          :command `("sh" "-c" "f=$1; shift; exec \"$@\" 2>\"$f\"" "sh" ,errors ,@claude-doctor-command)
                          :sentinel #'claude-doctor--done))
      (process-put claude-doctor--process 'stderr-file errors))))

;;; The scene

(defun claude-doctor--roles ()
  "The checks of the last answer that are a role's session."
  (seq-filter (lambda (c) (let ((id (alist-get 'id c)))
                            (or (member id claude-doctor-role-ids) (string-prefix-p "broker." id))))
              (alist-get 'checks claude-doctor--data)))

(defun claude-doctor--role-of (check)
  "The side role whose container a restart of CHECK's row recreates: the
mechanic's, or nil."
  (and (equal (alist-get 'id check) "mechanic.heartbeat") "mechanic"))

(defun claude-doctor--counts (checks)
  "The counts of CHECKS, as \"N ok · N warn · N fail · N unknown\"."
  (mapconcat (lambda (s) (format "%d %s" (cl-count s checks :key (lambda (c) (alist-get 'status c)) :test #'equal) s))
             '("ok" "warn" "fail" "unknown") " · "))

(defun claude-doctor--button (id label confirm action)
  "A button node ID that runs ACTION; CONFIRM is \"hold\" or nil."
  (puthash id action homun-stage-actions)
  `((type . "widget") (kind . "button") (id . ,id) (label . ,label)
    ,@(when confirm `((confirm . ,confirm)))))

(defun claude-doctor--row (check width)
  "The nodes of CHECK's row, its name padded to WIDTH, and of its hint when it has
one."
  (let-alist check
    (let ((service (and .service (member .status '("warn" "fail")) .service))
          (role (claude-doctor--role-of check)))
      `(((type . "row") (id . ,.id)
         (children
          ((type . "text") (face . ,(or (cdr (assoc .status claude-doctor-dots)) "dim")) (text . "●"))
          ((type . "text") (text . ,(string-pad .name width)))
          ((type . "text") (text . ,.summary))
          ,@(when service
              (list (claude-doctor--button (concat "restart-" .id) "Restart" "hold"
                                           (lambda () (claude-doctor-restart service)))))
          ,@(when role
              (list (claude-doctor--button (concat "restart-role-" .id) "Restart" "hold"
                                           (lambda () (claude-doctor-restart-role role)))))
          ,@(when .open
              (list (claude-doctor--button (concat "open-" .id) "Open" nil
                                           (lambda () (claude-doctor--open .open)))))))
        ,@(unless (string-empty-p (or .hint ""))
            `(((type . "text") (face . "dim") (text . ,(concat "      " .hint)))))))))

(defun claude-doctor-scene ()
  "The doctor scene tree from the last answer."
  (let* ((checks (claude-doctor--roles))
         (width (apply #'max 8 (mapcar (lambda (c) (string-width (alist-get 'name c))) checks))))
    `((type . "col")
      (children
       ((type . "row") (id . "head")
        (children
         ,(claude-doctor--button "refresh" "Refresh" nil #'claude-doctor-refresh)
         ((type . "text") (face . ,(cond (claude-doctor--problem "err") ((and claude-doctor--data (null checks)) "warn") (t "dim")))
          (text . ,(cond (claude-doctor--problem claude-doctor--problem)
                         ((and claude-doctor--data (null checks)) "unknown: no check answered")
                         (claude-doctor--data
                          (format "%s · seen from %s" (claude-doctor--counts checks)
                                  (alist-get 'where claude-doctor--data)))
                         (t "running the checks..."))))))
       ((type . "text") (text . ""))
       ,@(mapcan (lambda (c) (claude-doctor--row c width)) checks)))))

(defun claude-doctor--show-scene ()
  "Show or refresh the scene from the last answer; nothing while Cal is pressing a
button."
  (unless (bound-and-true-p widgetry-active-gesture)
    (let ((root (claude-doctor-scene)) (open (gethash claude-doctor-scene homun-stage-scenes)))
      (unless (and open (equal root (homun-stage-scene-root open)))
        (homun-stage-show "cal" claude-doctor-scene "Doctor" root "system")))))

;;; The timer: only while a window shows the scene

(defun claude-doctor--tick ()
  (if (and (gethash claude-doctor-scene homun-stage-scenes)
           (get-buffer-window (homun-stage-buffer-name claude-doctor-scene) t))
      (claude-doctor-refresh)
    (claude-doctor--stop)))

(defun claude-doctor--stop ()
  (when claude-doctor--timer (cancel-timer claude-doctor--timer))
  (setq claude-doctor--timer nil))

(defun claude-doctor--start ()
  "Look now and keep looking while a window shows the scene."
  (unless claude-doctor--timer
    (claude-doctor-refresh)
    (setq claude-doctor--timer
          (run-with-timer claude-doctor-interval claude-doctor-interval #'claude-doctor--tick))))

;;; Acting on a row

(defun claude-doctor--show (buffer)
  "Show BUFFER in the layout's main window when there is one, else pop to it."
  (if-let* ((main (homun-layout-window 'transcript)))
      (select-window (homun-layout-show buffer main))
    (pop-to-buffer buffer)))

(defun claude-doctor--tail (file)
  "A read-only buffer with the last 100 kB of FILE, point at its end."
  (let ((size (or (file-attribute-size (file-attributes file)) 0)))
    (with-current-buffer (get-buffer-create (format "*homun-doctor: %s*" (abbreviate-file-name file)))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert-file-contents file nil (max 0 (- size 100000)) size)
        (when (> size 100000) (goto-char (point-min)) (forward-line 1) (delete-region (point-min) (point))))
      (special-mode)
      (goto-char (point-max))
      (current-buffer))))

(defun claude-doctor--open (target)
  "Show what TARGET names: a buffer (buffer:NAME), a directory, or the tail of a
file."
  (cond ((string-prefix-p "buffer:" target)
         (claude-doctor--show (or (get-buffer (substring target 7))
                                  (user-error "No buffer %s" (substring target 7)))))
        ((file-directory-p target) (claude-doctor--show (dired-noselect target)))
        ((file-readable-p target)
         (let ((buffer (claude-doctor--tail target)))
           (claude-doctor--show buffer)
           (homun-layout-point (get-buffer-window buffer) (with-current-buffer buffer (point-max)))))
        (t (user-error "%s is not there (yet)" target))))

(defun claude-doctor--request (kind args)
  "Write a request of KIND with ARGS into the cockpit's part of the host spool;
return its id."
  (let* ((spool (expand-file-name "requests/cockpit" claude-doctor-host-dir))
         (stamp (floor (float-time)))
         (id (format "cockpit-%s-%d" kind stamp)))
    (unless (file-directory-p spool)
      (user-error "No host service spool at %s (on the host: homun host systemd add)" spool))
    (write-region (json-serialize `((id . ,id) (kind . ,kind) (from . "cockpit") (ts . ,stamp)
                                    (args . ,args)))
                  nil (expand-file-name (format ".%s.tmp" id) spool) nil 'silent)
    (rename-file (expand-file-name (format ".%s.tmp" id) spool)
                 (expand-file-name (format "%s.json" id) spool) t)
    id))

(defun claude-doctor--answer (id service tries)
  "Say what the host answered to request ID for SERVICE; look again up to TRIES
times."
  (let* ((file (expand-file-name (format "results/%s.json" id) claude-doctor-host-dir))
         (row (and (file-readable-p file)
                   (ignore-errors (claude-doctor--parse
                                   (with-temp-buffer (insert-file-contents file) (buffer-string)))))))
    (cond ((equal (alist-get 'state row) "done")
           (message "Restart of %s: %s" service (or (alist-get 'text row) "done"))
           (claude-doctor-refresh))
          ((> tries 0) (run-at-time 2 nil #'claude-doctor--answer id service (1- tries)))
          (t (message "Restart of %s: the host has not answered (is homun-host running, on this version?)"
                      service)))))

(defun claude-doctor-restart (service)
  "Ask the host to run `claude-services restart SERVICE' in the manager's
container."
  (claude-doctor--ask "service" `((action . "restart") (name . ,service)) service))

(defun claude-doctor-restart-role (role)
  "Ask the host service to recreate ROLE's container; nothing of that role is
needed for it."
  (claude-doctor--ask "side" `((action . "restart") (role . ,role)) role 40))

(defun claude-doctor--ask (kind args service &optional tries)
  "Send a request of KIND with ARGS to the host and follow its answer, worded for
SERVICE."
  (let ((id (claude-doctor--request kind args)))
    (message "Restart of %s requested..." service)
    (run-at-time 2 nil #'claude-doctor--answer id service (or tries 10))))

;;;###autoload
(defun claude-doctor ()
  "Show the doctor scene on the Stage: one row per role session."
  (interactive)
  (claude-doctor--show-scene)
  (homun-stage-display claude-doctor-scene)
  (claude-doctor--start))

(provide 'claude-doctor)
;;; claude-doctor.el ends here
