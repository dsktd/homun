;;; claude-remote-live.el --- Opt-in, volatile live reload of the cockpit's Elisp on a phone -*- lexical-binding: t -*-

;; Always on while the stream is up.  On every connect the phone compares the gateway's manifest with
;; what it has; a `reload' record while connected does the same.  Every changed or new file is fetched and
;; hash-checked first (one failure loads nothing), written to the cache dir `homun-dir' so every `require'
;; finds it, then evaluated in dependency order.  An Emacs restart fetches the installed package again.  Each pass logs
;; "auto-update homun VER: loaded N of M" to telemetry; a failure goes there with a backtrace and never
;; opens the debugger.

(require 'claude-remote)
(require 'subr-x)
(require 'homun-version)
(declare-function backtrace-get-frames "backtrace")
(declare-function backtrace-to-string "backtrace")

(defvar homun-dir)
(defvar claude-remote-live-version nil "The gateway's manifest version at the last turn-on.")
(defvar claude-remote-live--loaded nil "Alist of file name and sha256 evaluated by live reload.")
(declare-function claude-remote-report--push "claude-remote-report")

(defvar claude-remote-live-last nil "Text of the last auto-update pass.")
(declare-function claude-remote-report-error "claude-remote-report")

(defun claude-remote-live-active-p ()
  "Non-nil while the stream is up: live reload is always on then."
  (bound-and-true-p claude-remote-connected))

(defun claude-remote-live-status ()
  "One line for the Status tab: version and last update."
  (format "homun %s, %s" (or claude-remote-live-version (bound-and-true-p homun-version) "?")
          (or claude-remote-live-last "no update yet")))

(defun claude-remote-live-start ()
  "Compare the gateway's manifest with this Emacs and load what differs."
  (claude-remote--request "GET" "reload" nil #'claude-remote-live--catch-up))

(defun claude-remote-live--have (name)
  "The sha256 of NAME as this Emacs has it: evaluated live, else the fetched copy."
  (or (alist-get name claude-remote-live--loaded nil nil #'equal)
      (let ((file (and (boundp 'homun-dir) (expand-file-name (file-name-nondirectory name) homun-dir))))
        (and file (file-readable-p file)
             (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file)
                               (secure-hash 'sha256 (current-buffer)))))))

(defun claude-remote-live--say (text)
  "Show TEXT and report it to the gateway, so a reload that loaded nothing is
visible too."
  (message "%s" text)
  (setq claude-remote-live-last text)
  (when (fboundp 'claude-remote-report--push) (claude-remote-report--push "reload" text)))

;; Files of the manifest that belong to the host's own Emacs: never fetched or run here.
(defconst claude-remote-live--host-only '("init.el" "cockpit.el"))

(defun claude-remote-live--verified (reply name sha)
  "The content of the gateway's REPLY for NAME when it is 200 and hashes to SHA,
else nil."
  (let ((data (cdr reply)))
    (and (eql (car reply) 200)
         (equal (plist-get data :file) name) (equal (plist-get data :sha256) sha)
         (equal (secure-hash 'sha256 (encode-coding-string (plist-get data :content) 'utf-8)) sha)
         (plist-get data :content))))

(defun claude-remote-live--deps (content batch)
  "Names in BATCH (file names) that CONTENT requires at top level."
  (let (deps)
    (with-temp-buffer
      (insert content)
      (goto-char (point-min))
      (while (re-search-forward "^(require '\\([a-z0-9-]+\\)" nil t)
        (let ((file (concat (match-string 1) ".el")))
          (when (assoc file batch) (push file deps)))))
    deps))

(defun claude-remote-live--order (batch)
  "Names of BATCH (alist name . content), each after the batch files it requires."
  (let (order)
    (cl-labels ((visit (name trail)
                  (unless (or (member name order) (member name trail))
                    (dolist (dep (claude-remote-live--deps (cdr (assoc name batch)) batch))
                      (visit dep (cons name trail)))
                    (push name order))))
      (dolist (cell batch) (visit (car cell) nil)))
    (nreverse order)))

(defun claude-remote-live--install (batch)
  "Write every file of BATCH (name . content) to `homun-dir', then load them in
dependency order.
Return the names loaded.  The files are all on disk before the first one runs,
so a `require' of a file of the same batch always finds it."
  (let ((load-prefer-newer t))
    (dolist (cell batch)
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region (cdr cell) nil (expand-file-name (file-name-nondirectory (car cell)) homun-dir) nil 'silent)))
    (add-to-list 'load-path (directory-file-name homun-dir))
    (let (done)
      (dolist (name (claude-remote-live--order batch))
        (when (claude-remote-live--eval (cdr (assoc name batch)) name)
          (push name done)))
      done)))

(defun claude-remote-live--catch-up (reply)
  "Fetch every file of the manifest REPLY that differs from, or is missing on, this
Emacs.
Nothing is loaded until every one is fetched and its hash checked; one failure
loads nothing."
  (if (not (eql (car reply) 200))
      (claude-remote-live--say (format "auto-update: no manifest (%s)" (car reply)))
    (let* ((data (cdr reply)) (files (plist-get data :files)) stale)
      (setq claude-remote-live-version (plist-get data :version))
      (while files
        (let ((name (substring (symbol-name (pop files)) 1)) (sha (pop files)))
          (unless (or (member name claude-remote-live--host-only)
                      (equal sha (claude-remote-live--have name)))
            (push (cons name sha) stale))))
      (if (null stale)
          (claude-remote-live--say (format "auto-update homun %s: up to date" claude-remote-live-version))
        (let ((left (length stale)) got failed)
          (dolist (cell stale)
            (claude-remote--request
             "GET" (concat "reload?file=" (url-hexify-string (car cell))) nil
             (lambda (r)
               (let ((content (claude-remote-live--verified r (car cell) (cdr cell))))
                 (if content (push (cons (car cell) content) got) (push (car cell) failed)))
               (when (zerop (setq left (1- left)))
                 (claude-remote-live--finish stale got failed))))))))))

(defun claude-remote-live--unreadable (content)
  "Return nil when every top-level form of CONTENT reads, else the error text."
  (condition-case err
      (with-temp-buffer
        (set-syntax-table emacs-lisp-mode-syntax-table)
        (insert content)
        (goto-char (point-min))
        (while (progn (forward-comment (point-max)) (not (eobp))) (read (current-buffer)))
        nil)
    (error (format "line %d: %s" (line-number-at-pos) (error-message-string err)))))

(defun claude-remote-live--finish (stale got failed)
  "All of STALE answered: install GOT, or log FAILED and load nothing.
A file of GOT that does not read counts as failed, so one broken file loads
none."
  (dolist (cell got)
    (when-let* ((bad (claude-remote-live--unreadable (cdr cell))))
      (push (format "%s %s" (car cell) bad) failed)))
  (if (or failed (not (claude-remote-live-active-p)))
      (claude-remote-live--say
       (format "auto-update homun %s: loaded 0 of %d, fetch or parse failed (%s)" claude-remote-live-version
               (length stale) (string-join (sort failed #'string<) "; ")))
    (let ((done (claude-remote-live--install got)))
      (claude-remote-live--say
       (format "auto-update homun %s: loaded %d of %d (%s)" claude-remote-live-version
               (length done) (length stale) (string-join (sort done #'string<) " "))))))

(defun claude-remote-live--fail (err)
  "Report ERR with its backtrace to telemetry, from inside the handler."
  (when (fboundp 'claude-remote-report-error)
    (let ((debug-on-error nil))
      (ignore-errors
        (claude-remote-report-error
         err (truncate-string-to-width (backtrace-to-string (backtrace-get-frames #'claude-remote-live--fail)) 8000))))))

(defun claude-remote-live--eval (content name)
  "Evaluate CONTENT as the file NAME in memory and note its hash; non-nil if it
ran."
  (condition-case nil
      (handler-bind ((error #'claude-remote-live--fail))
        (with-temp-buffer
          (insert content)
          (setq lexical-binding t)
          (eval-buffer (current-buffer) nil name nil t)
          (setf (alist-get name claude-remote-live--loaded nil nil #'equal)
                (secure-hash 'sha256 (encode-coding-string content 'utf-8)))
          (message "live reload: %s" name)
          t))
    (error nil)))

(defun claude-remote-live--apply (reply name sha)
  "Evaluate the file NAME from the gateway's REPLY (STATUS . DATA) when its hash is
SHA; non-nil if done."
  (cond ((not (claude-remote-live-active-p)))
        ((not (claude-remote-live--verified reply name sha))
         (message "live reload: %s refused or does not match its hash, not evaluated" name))
        (t (claude-remote-live--eval (plist-get (cdr reply) :content) name))))

(defun claude-remote-live--record (kind source data)
  "A `reload' record: a file changed, so compare the whole manifest and load the
batch together."
  (when (and (equal kind "reload") (claude-remote-live-active-p))
    (let ((name (plist-get data :file)))
      (when (and (equal name source) (string-match-p "\\`\\(widgetry/\\)?[a-z0-9-]+\\.el\\'" name))
        (claude-remote-live-start)))))

(add-hook 'claude-remote-record-functions #'claude-remote-live--record)
(add-hook 'claude-remote-connected-hook #'claude-remote-live-start)

(provide 'claude-remote-live)
;;; claude-remote-live.el ends here
