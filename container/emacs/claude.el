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

(provide 'claude)
;;; claude.el ends here