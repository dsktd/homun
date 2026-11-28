;;; claude-transcript-past.el --- search the past sessions of a role -*- lexical-binding: t -*-
;; A rotated session leaves the role's transcript buffer, so its history cannot be searched
;; there.  `claude-transcript-past' (g/) searches every session the role has had: the ids in
;; the role's start.log (every "role-pin" and "rotating A to B" line names one) whose file
;; exists next to the current one.  ripgrep runs asynchronously over the files; only what the
;; user and the assistant wrote counts.  Hits are listed newest session first; RET opens the
;; hit in a read-only transcript of a slice of its session (the turn before, the hit's, the
;; turn after), drawn by the transcript's own renderer.
(require 'cl-lib)
(require 'subr-x)
(require 'claude-transcript)

(defcustom claude-transcript-past-state-directory "~/claude/.services"
  "The directory holding one directory per role, with the role's start.log."
  :type 'directory :group 'claude-transcript)

(defcustom claude-transcript-past-context 1
  "How many turns before and after the hit's turn the read-only view shows."
  :type 'natnum :group 'claude-transcript)

(defconst claude-transcript-past--id-regexp
  "[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{12\\}"
  "A session id.")

(defun claude-transcript-past--ids (role)
  "The session ids of ROLE in its start.log, in the order the log names them."
  (let ((log (expand-file-name (format "%s/start.log" role)
                               claude-transcript-past-state-directory))
        ids)
    (when (file-readable-p log)
      (with-temp-buffer
        (insert-file-contents log)
        (while (re-search-forward
                (concat "\\(?:role-pin: session [a-z]+ (\\|rotating \\| to \\)\\("
                        claude-transcript-past--id-regexp "\\)")
                nil t)
          (cl-pushnew (match-string 1) ids :test #'equal))))
    (nreverse ids)))

(defun claude-transcript-past--files (role dir)
  "The existing session files of ROLE in DIR, the newest first."
  (sort (delq nil (mapcar (lambda (id)
                            (let ((file (expand-file-name (concat id ".jsonl") dir)))
                              (and (file-readable-p file) file)))
                          (claude-transcript-past--ids role)))
        :key #'claude-transcript--mtime :reverse t))

;;;; Results

(defvar-local claude-transcript-past--query nil "The query of this results buffer.")
(defvar-local claude-transcript-past--speaker nil "Name of the assistant in the hits.")
(defvar-local claude-transcript-past--process nil "The running ripgrep, or nil.")
(defvar-local claude-transcript-past--count 0 "Hits listed so far.")

(defun claude-transcript-past--header ()
  "The header line: the query, the hits and whether the search still runs."
  (format " Past sessions: %s  (%d hits%s)" claude-transcript-past--query
          claude-transcript-past--count
          (if (process-live-p claude-transcript-past--process) ", searching…" "")))

(defun claude-transcript-past--row (hit)
  "The line of HIT: date, speaker and snippet; the hit is a property of the whole line."
  (propertize
   (concat (propertize (format-time-string "%F %R" (encode-time (iso8601-parse (plist-get hit :stamp))))
                       'face 'claude-transcript-time)
           "  "
           (propertize (format "%-8s" (plist-get hit :who)) 'face 'claude-transcript-tool-name)
           " " (plist-get hit :snippet) "\n")
   'claude-transcript-past-hit hit))

(defun claude-transcript-past--insert (buffer lines)
  "Add the hits of the ripgrep LINES, rows `file:offset:json', to BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t) (query claude-transcript-past--query))
        (save-excursion
          (goto-char (point-max))
          (dolist (row lines)
            (when (string-match "\\`\\(.+?\\.jsonl\\):\\([0-9]+\\):" row)
              (let ((file (match-string 1 row))
                    (offset (string-to-number (match-string 2 row))))
                (dolist (hit (let ((claude-transcript--speaker claude-transcript-past--speaker))
                               (claude-transcript-search--hits
                                (substring row (match-end 0)) offset query t)))
                  (insert (claude-transcript-past--row (plist-put hit :file file)))
                  (cl-incf claude-transcript-past--count))))))))))

(defun claude-transcript-past--filter (buffer)
  "A process filter adding the complete lines of the output to BUFFER."
  (let ((pending ""))
    (lambda (_process output)
      (let* ((text (concat pending output))
             (lines (split-string text "\n"))
             (pending-line (car (last lines))))
        (setq pending pending-line)
        (claude-transcript-past--insert buffer (butlast lines))))))

(defun claude-transcript-past--start (buffer files)
  "Run ripgrep over FILES (in this order) for the query of BUFFER."
  (with-current-buffer buffer
    (when (process-live-p claude-transcript-past--process)
      (delete-process claude-transcript-past--process))
    (setq claude-transcript-past--count 0)
    (let ((inhibit-read-only t)) (erase-buffer))
    (setq claude-transcript-past--process
          (make-process
           :name "claude-transcript-past" :noquery t :connection-type 'pipe
           :coding 'utf-8-unix :buffer nil :stderr nil
           :command `("rg" "--no-config" "--threads" "1" "--with-filename" "--byte-offset"
                      "--no-heading" "--fixed-strings" "--ignore-case" "--max-columns" "0"
                      "-e" ,claude-transcript-past--query "--" ,@files)
           :filter (claude-transcript-past--filter buffer)
           :sentinel (lambda (_process _event)
                       (when (buffer-live-p buffer)
                         (with-current-buffer buffer (force-mode-line-update))))))))

(defvar-keymap claude-transcript-past-mode-map
  :parent special-mode-map
  "RET" #'claude-transcript-past-visit
  "g" #'claude-transcript-past-again)

(define-derived-mode claude-transcript-past-mode special-mode "Past"
  "Hits of a search over the past sessions of a role; RET opens one."
  (setq-local header-line-format '(:eval (claude-transcript-past--header))
              truncate-lines t))

(with-eval-after-load 'evil
  (declare-function evil-define-key* "evil-core")
  (evil-define-key* '(normal motion) claude-transcript-past-mode-map
    (kbd "RET") #'claude-transcript-past-visit (kbd "gr") #'claude-transcript-past-again))

;;;###autoload
(defun claude-transcript-past (query)
  "Search the past sessions of this transcript's role for QUERY.
The list fills as ripgrep finds hits; RET on one opens it read-only."
  (interactive (list (read-string "Search past sessions: " (thing-at-point 'symbol t))))
  (unless (and claude-transcript--role claude-transcript--file)
    (user-error "Not in the transcript of a role"))
  (unless (executable-find "rg") (user-error "ripgrep (rg) is not on the exec path"))
  (when (string-empty-p query) (user-error "Empty query"))
  (let* ((role claude-transcript--role)
         (files (or (claude-transcript-past--files
                     role (file-name-directory claude-transcript--file))
                    (user-error "No past sessions of %s found" role)))
         (speaker (and claude-transcript--speaker
                       (substring-no-properties claude-transcript--speaker)))
         (buffer (get-buffer-create (format "*past: %s*" role))))
    (with-current-buffer buffer
      (claude-transcript-past-mode)
      (setq claude-transcript-past--query query
            claude-transcript-past--speaker speaker))
    (claude-transcript-past--start buffer files)
    (pop-to-buffer buffer)))

(defun claude-transcript-past-again ()
  "Run the search of this buffer again."
  (interactive)
  (let ((role (string-remove-suffix "*" (string-remove-prefix "*past: " (buffer-name))))
        (query claude-transcript-past--query))
    (if-let* ((transcript (claude-transcript--find nil role)))
        (with-current-buffer transcript (claude-transcript-past query))
      (user-error "No transcript of %s" role))))

;;;; The read-only view

(defun claude-transcript-past--slice (file offset context)
  "Return (TEXT . OFFSET) of the slice of FILE around the line at OFFSET.
TEXT holds the whole turns from CONTEXT turns before the turn of that line to
CONTEXT turns after it; OFFSET is where that line starts in TEXT."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (let ((line (lambda () (buffer-substring-no-properties (line-beginning-position)
                                                           (line-end-position))))
          (hit (1+ offset)) start end)
      (goto-char hit)
      (forward-line 0)
      (setq hit (point))
      (let ((n (1+ context)))
        (goto-char (line-end-position))
        (while (and (> n 0) (re-search-backward "\"type\": ?\"user\"" nil t))
          (when (claude-transcript-search--prompt-p (funcall line))
            (cl-decf n)
            (setq start (line-beginning-position)))))
      (setq start (or start (point-min)))
      (goto-char hit)
      (forward-line 1)
      (let ((n (1+ context)))
        (while (and (> n 0) (re-search-forward "\"type\": ?\"user\"" nil t))
          (when (claude-transcript-search--prompt-p (funcall line))
            (cl-decf n)
            (setq end (line-beginning-position)))))
      (setq end (or end (point-max)))
      (cons (buffer-substring-no-properties start end) (- hit start)))))

(defun claude-transcript-past--view (hit)
  "Show HIT in a read-only transcript of the slice of its session."
  (let* ((file (plist-get hit :file))
         (slice (claude-transcript-past--slice file (plist-get hit :offset)
                                               claude-transcript-past-context))
         (dir (make-temp-file "claude-past" t))
         (copy (expand-file-name (file-name-nondirectory file) dir))
         (speaker claude-transcript-past--speaker)
         (buffer (generate-new-buffer
                  (format "*past: %s %s*" (file-name-base file)
                          (format-time-string "%F %R" (encode-time
                                                       (iso8601-parse (plist-get hit :stamp))))))))
    (let ((coding-system-for-write 'no-conversion))
      (write-region (car slice) nil copy nil 'silent))
    (with-current-buffer buffer
      (claude-transcript-mode)
      (setq claude-transcript--file copy
            claude-transcript-follow 'off)
      (add-hook 'kill-buffer-hook (lambda () (delete-directory dir t)) nil t)
      (claude-transcript--set-speaker)
      (when speaker (setq claude-transcript--speaker speaker))
      (claude-transcript--render (* 2 (1+ claude-transcript-past-context)))
      (claude-transcript-search--show
       (plist-put (copy-sequence hit) :offset (cdr slice))
       (plist-get hit :query) t))
    (pop-to-buffer-same-window buffer)))

(defun claude-transcript-past-visit ()
  "Open the hit at point read-only, with the turns around it."
  (interactive)
  (claude-transcript-past--view
   (or (get-text-property (line-beginning-position) 'claude-transcript-past-hit)
       (user-error "No hit here"))))

(provide 'claude-transcript-past)
;;; claude-transcript-past.el ends here
