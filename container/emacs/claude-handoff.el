;;; claude-handoff.el --- Handoff sessions in the user's Emacs -*- coding: utf-8; lexical-binding: t -*-

;; A handoff session is a fresh headless Claude Code session the manager briefed for the user
;; (bin/claude-handoff).  `claude-handoff-open' gives one a tab "≡ NAME": its transcript
;; (claude-transcript on the session JSONL) with a compose box below whose route sends to that
;; session instead of the cal channel.  State is read from ~/claude/.services/handoff/<n>/;
;; start and stop go through the CLI, which queues them for the Manager's `handoff' service.

(require 'cl-lib)
(require 'subr-x)

(declare-function claude-compose-route--make "claude-compose")
(declare-function claude-compose--show "claude-compose")
(declare-function claude-transcript-open "claude-transcript")

(defvar claude-handoff-program
  (list "nu" (expand-file-name "~/claude/_tools/homun/bin/claude-handoff"))
  "The handoff CLI.")

(defvar claude-handoff-dir (expand-file-name "~/claude/.services/handoff")
  "Where each handoff session keeps its directory.")

;;; State

(defun claude-handoff--file (name file)
  (expand-file-name file (expand-file-name name claude-handoff-dir)))

(defun claude-handoff--running-p (name)
  "Non-nil when NAME was launched and has neither exited nor been stopped."
  (and (file-exists-p (claude-handoff--file name "pid"))
       (not (file-exists-p (claude-handoff--file name "exit")))
       (not (file-exists-p (claude-handoff--file name "stopped")))))

(defun claude-handoff--meta (name)
  "The meta.json of NAME as a plist with :running added, or nil."
  (let ((file (claude-handoff--file name "meta.json")))
    (when (file-readable-p file)
      (let ((meta (with-temp-buffer
                    (insert-file-contents file)
                    (json-parse-buffer :object-type 'plist))))
        (plist-put meta :running (claude-handoff--running-p name))))))

(defun claude-handoff-list ()
  "Every handoff session, newest first, as meta plists."
  (when (file-directory-p claude-handoff-dir)
    (sort (delq nil (mapcar #'claude-handoff--meta
                            (directory-files claude-handoff-dir nil "\\`[a-z0-9][a-z0-9-]*\\'")))
          (lambda (a b) (string> (plist-get a :started) (plist-get b :started))))))

(defun claude-handoff-summary (name)
  "The one-line summary NAME left when it stopped, or nil."
  (let ((file (claude-handoff--file name "summary")))
    (when (file-readable-p file)
      (string-trim (with-temp-buffer (insert-file-contents file) (buffer-string))))))

;;; The CLI, always async

(defun claude-handoff--run (args &optional input done)
  "Run the CLI with ARGS (and INPUT on stdin); DONE gets the trimmed output and
exit status."
  (let* ((out (generate-new-buffer " *claude-handoff*" t))
         (proc (make-process
                :name "claude-handoff" :buffer out :noquery t :connection-type 'pipe
                :coding 'utf-8-unix :command (append claude-handoff-program args)
                :sentinel (lambda (proc _event)
                            (unless (process-live-p proc)
                              (let ((text (with-current-buffer out (string-trim (buffer-string))))
                                    (status (process-exit-status proc)))
                                (kill-buffer out)
                                (if done (funcall done text status)
                                  (message "%s" text))))))))
    (when input (process-send-string proc input))
    (process-send-eof proc)
    proc))

(defun claude-handoff-start (name brief &optional dir)
  "Start the handoff NAME with the BRIEF text, working in DIR (default
~/claude/NAME/)."
  (interactive (list (read-string "Handoff name: ")
                     (read-string "Brief: ")))
  (let ((file (make-temp-file "handoff-brief-" nil ".md" brief)))
    (claude-handoff--run (append (list "start" "name" name "brief" file)
                                 (when (and dir (not (string-empty-p dir))) (list "dir" dir)))
                         nil (lambda (text _status) (delete-file file) (message "%s" text)))))

(defun claude-handoff-send (name text)
  "Send TEXT to the handoff NAME."
  (claude-handoff--run (list "send" "name" name "text" "-") text))

(defun claude-handoff-stop (name)
  "Stop the handoff NAME; it leaves a one-line summary first."
  (interactive (list (completing-read "Stop handoff: "
                                      (mapcar (lambda (m) (plist-get m :name))
                                              (seq-filter (lambda (m) (plist-get m :running))
                                                          (claude-handoff-list)))
                                      nil t)))
  (claude-handoff--run (list "stop" "name" name)))

;;; Tab: transcript above, compose below

(defun claude-handoff-route (name)
  "The compose route that talks to the handoff NAME."
  (require 'claude-compose)
  (claude-compose-route--make
   :role 'handoff :buffer (format "*claude-compose: ≡ %s*" name)
   :send (append claude-handoff-program (list "send" "name" name "text" "-"))
   :who (append claude-handoff-program (list "who" "name" name))))

(defun claude-handoff-route-for-file (file)
  "The route of the handoff whose transcript is FILE, or nil."
  (when-let* ((file)
              (meta (seq-find (lambda (m) (equal (plist-get m :jsonl) (expand-file-name file)))
                              (claude-handoff-list))))
    (claude-handoff-route (plist-get meta :name))))

(defun claude-handoff-open (name)
  "Show the handoff NAME in a tab of its own, labelled \"≡ NAME\"."
  (interactive (list (completing-read "Handoff: " (mapcar (lambda (m) (plist-get m :name))
                                                          (claude-handoff-list))
                                      nil t)))
  (let* ((meta (or (claude-handoff--meta name) (user-error "No handoff %s" name)))
         (label (concat "≡ " name))
         (file (plist-get meta :jsonl)))
    (if (tab-bar--tab-index-by-name label)
        (tab-bar-switch-to-tab label)
      (tab-bar-new-tab)
      (tab-bar-rename-tab label)
      (unless (file-exists-p file) (user-error "%s has no transcript yet; try again shortly" name))
      (require 'claude-transcript)
      (claude-transcript-open file)
      ;; claude-compose's advice opens the box when it knows the file; make sure it does
      (claude-compose--show (claude-handoff-route name)))))

(provide 'claude-handoff)
;;; claude-handoff.el ends here
