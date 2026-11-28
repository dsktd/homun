;;; claude-reload.el --- Load the cockpit's Elisp again when it changes on disk -*- lexical-binding: t -*-

;; The daemon watches the directories of the files in `claude-reload-files' (file-notify, so an
;; editor's rename-over-write is seen too).  A change arms a per-file timer; once the file has
;; stopped changing (same size and mtime on two looks `claude-reload-settle' seconds apart) and
;; reads as complete forms, its source (never a stale .elc) is loaded, the buffers it draws are
;; redrawn and one line goes to the events log (event "reload", file, ok or error).  A file that
;; does not read keeps the old definitions and toasts; one that fails mid-load keeps what ran.
;; Loading never writes a watched file, so it cannot loop.  `claude-auto-reload' turns it off.

;;; Code:

(require 'filenotify)
(require 'json)
(require 'subr-x)

(defcustom claude-auto-reload t
  "Load a cockpit Elisp file again when it changes on disk."
  :type 'boolean :group 'claude)

(defvar claude-reload-settle 1.0 "Seconds a file must stay unchanged before it is loaded.")

(defvar claude-reload-files
  (list (concat (or (getenv "CLAUDE_EMACS_CONF") "/opt/homun/emacs") "/claude-*.el")
        (concat (or (getenv "CLAUDE_EMACS_CONF") "/opt/homun/emacs") "/homun-api.el")
        (concat (or (getenv "CLAUDE_EMACS_CONF") "/opt/homun/emacs") "/widgetry/widgetry*.el"))
  "File names and globs to watch.")

(defvar claude-reload-log (expand-file-name "~/claude/.services/events/log.jsonl"))

(defvar claude-reload--watches nil "Descriptors from `file-notify-add-watch'.")
(defvar claude-reload--timers nil "Alist of (FILE . timer) of pending loads.")
(defvar claude-reload--seen nil "Alist of (FILE . (MTIME . SIZE)) of what was last loaded.")

(defun claude-reload--matches-p (file)
  "Non-nil when FILE is a source file `claude-reload-files' names."
  (and (string-suffix-p ".el" file)
       (cl-some (lambda (pattern)
                  (string-match-p (wildcard-to-regexp pattern) file))
                claude-reload-files)))

(defun claude-reload--stamp (file)
  "(MTIME . SIZE) of FILE, or nil."
  (when-let* ((attrs (file-attributes file)))
    (cons (float-time (file-attribute-modification-time attrs)) (file-attribute-size attrs))))

(defun claude-reload--readable-p (file)
  "Non-nil when FILE is made of complete forms."
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (condition-case nil (progn (check-parens) t) (error nil))))

(defun claude-reload--log (file ok detail)
  "Append the \"reload\" event of FILE to the events log."
  (ignore-errors
    (make-directory (file-name-directory claude-reload-log) t)
    (write-region (concat (json-serialize
                           `((ts . ,(floor (float-time))) (event . "reload") (session . "")
                             (kind . ,(if ok "ok" "error")) (file . ,(file-name-nondirectory file))
                             (summary . ,(format "%s %s" (file-name-nondirectory file)
                                                 (if ok "reloaded" (concat "failed: " detail))))))
                          "\n")
                  nil claude-reload-log 'append 'silent)))

(defun claude-reload--redraw ()
  "Redraw the buffers whose code may have changed."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (ignore-errors
        (cond ((and (derived-mode-p 'claude-board-mode) (fboundp 'claude-board--draw))
               (claude-board--draw))
              ((and (derived-mode-p 'claude-transcript-mode) (fboundp 'claude-transcript-refresh))
               (claude-transcript-refresh))
              ((and (derived-mode-p 'claude-update-mode) (fboundp 'claude-update--draw))
               (claude-update--draw)))))))

(defun claude-reload-file (file)
  "Load the source of FILE, redraw and log; return non-nil on success."
  (let ((name (file-name-nondirectory file)))
    (if (not (claude-reload--readable-p file))
        (progn (claude-reload--log file nil "does not read (kept the old definitions)")
               (message "Claude reload: %s does not read; kept the old definitions" name)
               nil)
      (condition-case err
          (progn (add-to-list 'load-path (file-name-directory file) t) ; a new file's requires
                 (load file nil t t)
                 (claude-reload--redraw)
                 (claude-reload--log file t "")
                 t)
        (error (claude-reload--log file nil (error-message-string err))
               (message "Claude reload: %s failed: %s" name (error-message-string err))
               nil)))))

(defun claude-reload--settled (file before)
  "Load FILE if its stamp still equals BEFORE, else look again later."
  (setf (alist-get file claude-reload--timers nil 'remove #'equal) nil)
  (let ((now (claude-reload--stamp file)))
    (cond ((null now))
          ((not (equal now before)) (claude-reload--arm file now))
          ((equal now (alist-get file claude-reload--seen nil nil #'equal)))
          (t (setf (alist-get file claude-reload--seen nil nil #'equal) now)
             (claude-reload-file file)))))

(defun claude-reload--arm (file &optional stamp)
  "Look at FILE again in `claude-reload-settle' seconds."
  (when-let* ((old (alist-get file claude-reload--timers nil nil #'equal)))
    (cancel-timer old))
  (let ((stamp (or stamp (claude-reload--stamp file))))
    (setf (alist-get file claude-reload--timers nil nil #'equal)
          (run-with-timer claude-reload-settle nil #'claude-reload--settled file stamp))))

(defun claude-reload--event (event)
  (pcase-let ((`(,_ ,action ,file . ,rest) event))
    (let ((target (if (eq action 'renamed) (car rest) file)))
      (when (and claude-auto-reload (memq action '(changed created renamed))
                 (stringp target) (claude-reload--matches-p target))
        (claude-reload--arm target)))))

(defun claude-reload-start ()
  "Watch the directories of `claude-reload-files'."
  (claude-reload-stop)
  (dolist (dir (delete-dups (mapcar (lambda (p) (file-name-directory p)) claude-reload-files)))
    (when (file-directory-p dir)
      (push (file-notify-add-watch dir '(change) #'claude-reload--event) claude-reload--watches))))

(defun claude-reload-stop ()
  (mapc #'file-notify-rm-watch claude-reload--watches)
  (setq claude-reload--watches nil)
  (mapc (lambda (c) (cancel-timer (cdr c))) claude-reload--timers)
  (setq claude-reload--timers nil))

(provide 'claude-reload)
;;; claude-reload.el ends here
