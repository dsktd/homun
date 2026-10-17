;;; claude.el --- What the claude-emacs CLI calls over emacsclient -*- lexical-binding: t -*-

;; Each command is one `emacsclient -e' form from bin/claude-emacs. They show
;; things in a GUI frame, creating one when the daemon has none, and never
;; block: `claude-ask' returns at once and writes the answer to a file under
;; answers/ when the user submits it, which the CLI waits for.

(defvar claude-answers-dir (expand-file-name "answers/" claude-service-dir)
  "Where `claude-ask' writes answers: <id> on submit, <id>.declined on decline.")

(defun claude--gui-frame ()
  "A frame on the display, made when the daemon only has its terminal frame."
  (or (seq-find (lambda (f) (frame-parameter f 'window-system)) (frame-list))
      (make-frame `((window-system . ,(if (featurep 'pgtk) 'pgtk 'x))))))

(defmacro claude--with-frame (&rest body)
  "Run BODY with a GUI frame selected, then give that frame focus.
In batch there is no display: BODY runs in the current frame."
  (declare (indent 0))
  `(if noninteractive
       (progn ,@body)
     (let ((frame (claude--gui-frame)))
       (with-selected-frame frame ,@body)
       (select-frame-set-input-focus frame))))

(defun claude--notify (summary body)
  "Desktop notification through the container's notify proxy, if there is one."
  (when (executable-find "notify-send")
    (ignore-errors (call-process "notify-send" nil 0 nil summary body))))

(defun claude-open (file &optional line)
  "Visit FILE, at LINE when given, in a frame."
  (claude--with-frame
    (find-file file)
    (when line
      (goto-char (point-min))
      (forward-line (1- line))))
  file)

(defun claude-open-dir (dir)
  "Show DIR in the selected frame: magit when it is in a git work tree, dired otherwise.
For `c emacs' without a file, which runs this in the frame it just made."
  (let ((default-directory (file-name-as-directory dir)))
    (if (and (fboundp 'magit-toplevel) (magit-toplevel))
        (magit-status-setup-buffer default-directory)
      (dired default-directory)))
  dir)

(defun claude-diff (a b)
  "Compare files A and B with ediff."
  (claude--with-frame (ediff-files a b))
  t)

(defun claude-report (file &optional title)
  "Show FILE read-only in a buffer named after TITLE (`q' closes it)."
  (let ((buffer (get-buffer-create
                 (format "*claude report: %s*" (or title (file-name-nondirectory file))))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert-file-contents file))
      (let ((buffer-file-name file))
        (set-auto-mode))
      (view-mode 1))
    (claude--with-frame (switch-to-buffer buffer))
    (buffer-name buffer)))

(defun claude-say (text)
  "Show TEXT in the echo area."
  (message "%s" text)
  text)

;;; ask

(defvar-local claude-ask-id nil)
(defvar-local claude-ask-answer-start nil)
(defvar-local claude-ask-timed-out nil)

(defun claude--ask-buffer-name (id)
  (format "*claude ask %s*" id))

(defvar claude-ask-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'claude-ask-submit)
    (define-key map (kbd "C-c C-k") #'claude-ask-decline)
    map))

(define-derived-mode claude-ask-mode text-mode "Claude-Ask"
  "Answer Claude's question below the line; C-c C-c sends it, C-c C-k declines.")

(defun claude-ask (text id)
  "Put question TEXT in its own *claude ask ID* buffer; the answer lands in answers/ID.
Returns ID."
  (make-directory claude-answers-dir t)
  (let ((buffer (get-buffer-create (claude--ask-buffer-name id))))
    (with-current-buffer buffer
      (claude-ask-mode)
      (setq claude-ask-id id)
      ;; The question is read-only; the answer goes after it (rear-nonsticky)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (concat text "\n\n") 'read-only t 'front-sticky t)
                (propertize (concat (make-string 72 ?-) "\n"
                                    "Answer below. C-c C-c sends it, C-c C-k declines.\n")
                            'read-only t 'front-sticky t 'rear-nonsticky t
                            'face 'font-lock-comment-face)))
      (setq claude-ask-answer-start (point-marker)))
    (claude--with-frame
      (switch-to-buffer buffer)
      (goto-char (point-max))
      (when (fboundp 'evil-insert-state) (evil-insert-state)))
    (claude--notify "Claude asks" text)
    id))

(defun claude-ask-timeout (id)
  "Mark ask ID's buffer: the CLI stopped waiting, so an answer goes nowhere."
  (when-let* ((buffer (get-buffer (claude--ask-buffer-name id))))
    (with-current-buffer buffer
      (setq claude-ask-timed-out t
            header-line-format
            (propertize " Timed out: Claude stopped waiting, an answer here is not delivered (q or C-c C-k closes)"
                        'face 'error))))
  id)

(defun claude-ask--finish (answer suffix)
  "Write ANSWER to answers/<id><SUFFIX> atomically and drop the buffer.
Nothing is written once the ask timed out: nobody would read it."
  (unless claude-ask-id (user-error "Not a claude ask buffer"))
  (if claude-ask-timed-out
      (message "Claude stopped waiting for this answer; not delivered")
    (let* ((file (expand-file-name (concat claude-ask-id suffix) claude-answers-dir))
           (tmp (concat file ".tmp")))
      (write-region answer nil tmp nil 'silent)
      (rename-file tmp file t)))
  (kill-buffer))

(defun claude-ask-submit ()
  "Send what is below the line to Claude."
  (interactive)
  (claude-ask--finish
   (string-trim (buffer-substring-no-properties claude-ask-answer-start (point-max)))
   ""))

(defun claude-ask-decline ()
  "Tell Claude there is no answer."
  (interactive)
  (claude-ask--finish "" ".declined"))

;;; queue: bugs and feature requests for the Manager

(defgroup claude nil "Claude's Emacs." :group 'tools)

(defcustom claude-queue-memory-dir
  (expand-file-name "~/.claude/projects/-home-purplg-claude/memory/")
  "The Manager's memory directory, where `claude-queue' files each item."
  :type 'directory)

(defun claude-queue--slug (title)
  "TITLE in kebab-case, for a file name."
  (let ((slug (string-trim (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase title)) "-+" "-+")))
    (if (string-empty-p slug) "item" slug)))

(defun claude-queue-write (kind title body &optional dir)
  "File a KIND (\"bug\" or \"feature\") item TITLE with BODY as a memory in DIR.
DIR defaults to `claude-queue-memory-dir'. Writes queue-<slug>.md, adding a
numeric suffix rather than overwriting, and indexes it in MEMORY.md.
Returns the file written."
  (let* ((dir (file-name-as-directory (or dir claude-queue-memory-dir)))
         (base (concat "queue-" (claude-queue--slug title)))
         (slug base)
         (n 1))
    (make-directory dir t)
    (while (file-exists-p (expand-file-name (concat slug ".md") dir))
      (setq n (1+ n) slug (format "%s-%d" base n)))
    (let ((file (expand-file-name (concat slug ".md") dir))
          (body (string-trim body)))
      (with-temp-file file
        (insert "---\nname: " slug "\n"
                "description: " kind ": " title "\n"
                "metadata:\n  type: project\n---\n\n"
                (if (string-empty-p body) "" (concat body "\n\n"))
                "Queued " (format-time-string "%F") " from Emacs.\n"))
      (let ((index (expand-file-name "MEMORY.md" dir)))
        (with-temp-buffer
          (when (file-exists-p index)
            (insert-file-contents index))
          (goto-char (point-max))
          (unless (or (bobp) (bolp)) (insert "\n"))
          (insert (format "- [Queue: %s](%s.md) — %s, queued from Emacs\n" title slug kind))
          (write-region nil nil index nil 'silent)))
      file)))

(defvar-local claude-queue-kind nil)
(defvar-local claude-queue-title nil)

(defvar claude-queue-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'claude-queue-finish)
    (define-key map (kbd "C-c C-k") #'claude-queue-abort)
    map))

(define-derived-mode claude-queue-mode text-mode "Claude-Queue"
  "Describe the item; C-c C-c queues it for the Manager, C-c C-k aborts.")

(defun claude-queue (kind title)
  "Queue a bug or feature request TITLE for the Manager, described in a capture buffer."
  (interactive
   (list (completing-read "Kind: " '("bug" "feature") nil t)
         (read-string "Title: ")))
  (when (string-blank-p title) (user-error "Empty title"))
  (let ((buffer (generate-new-buffer (format "*claude queue %s*" kind))))
    (with-current-buffer buffer
      (claude-queue-mode)
      (setq claude-queue-kind kind
            claude-queue-title title
            header-line-format
            (format " %s: %s  (C-c C-c queues, C-c C-k aborts)" kind title)))
    (pop-to-buffer buffer)
    (when (fboundp 'evil-insert-state) (evil-insert-state))))

(defun claude-queue-finish ()
  "Write this capture buffer's item to the Manager's memory."
  (interactive)
  (unless claude-queue-kind (user-error "Not a claude queue buffer"))
  (let ((file (claude-queue-write claude-queue-kind claude-queue-title
                                  (buffer-substring-no-properties (point-min) (point-max)))))
    (claude--kill-capture)
    (message "Queued for Claude: %s" (abbreviate-file-name file))))

(defun claude-queue-abort ()
  "Drop this capture buffer without queuing anything."
  (interactive)
  (claude--kill-capture)
  (message "Queue aborted"))

(defun claude--kill-capture ()
  "Kill the buffer, and its window too when it is not the only one."
  (if (one-window-p) (kill-buffer) (kill-buffer-and-window)))

;;; sched: the scheduler's upcoming fires in org-agenda

(defcustom claude-sched-url "http://127.0.0.1:8424/agenda.org"
  "The scheduler's agenda, an org file of its upcoming fires."
  :type 'string)

(defcustom claude-sched-file (expand-file-name "~/.cache/claude/sched.org")
  "Where `claude-sched-refresh' keeps the agenda; it is in `org-agenda-files'."
  :type 'file)

(defcustom claude-sched-command
  (list "nu" (expand-file-name "~/claude/_tools/claude-wrapper/bin/claude-sched"))
  "The claude-sched CLI, which validates what the commands below send it."
  :type '(repeat string))

(defun claude-sched-refresh ()
  "Fetch the agenda into `claude-sched-file'; on failure keep the old file."
  (interactive)
  (make-directory (file-name-directory claude-sched-file) t)
  (condition-case err
      (url-copy-file claude-sched-url claude-sched-file t)
    (error (message "claude-sched: not refreshed: %s" (error-message-string err)))))

(defun claude-sched--call (&rest args)
  "Run the claude-sched CLI with ARGS, show its output, and refresh the agenda."
  (with-temp-buffer
    (let ((status (apply #'call-process (car claude-sched-command) nil t nil
                         (append (cdr claude-sched-command) args))))
      (message "claude-sched %s: %s" (string-join args " ") (string-trim (buffer-string)))
      (unless (eq status 0) (message "claude-sched failed (exit %s)" status))))
  (claude-sched-refresh))

(defun claude-sched-add (name cron prompt)
  "Add schedule NAME firing on CRON (5 fields) with PROMPT."
  (interactive (list (read-string "Name: ") (read-string "Cron (5 fields): ")
                     (read-string "Prompt: ")))
  (claude-sched--call "add" name "cron" cron "prompt" prompt))

(defun claude-sched-toggle (name enable)
  "Enable (ENABLE non-nil) or disable schedule NAME."
  (interactive (list (read-string "Schedule: ") (y-or-n-p "Enable (n disables)? ")))
  (claude-sched--call (if enable "enable" "disable") name))

(defun claude-sched-run (name)
  "Fire schedule NAME now."
  (interactive "sFire schedule now: ")
  (claude-sched--call "run" name))

(unless noninteractive (run-with-timer 0 300 #'claude-sched-refresh))
(with-eval-after-load 'org-agenda
  (add-to-list 'org-agenda-files claude-sched-file)
  (advice-add 'org-agenda :before (lambda (&rest _) (claude-sched-refresh))))

(provide 'claude)
;;; claude.el ends here