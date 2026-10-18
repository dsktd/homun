;;; claude-answer.el --- Answer a claude-question in a popup window  -*- lexical-binding: t; -*-

;; A question of the dashboard opens in a window below it, laid out like
;; magit's commit message buffer: the question, its options as checkboxes,
;; then a free-text area. C-c C-c sends the answer, C-c C-k cancels.

(require 'subr-x)

(defvar claude-dashboard-question-program)
(declare-function claude-dashboard-refresh "claude-dashboard")
(declare-function evil-define-key "evil-core")
(declare-function evil-insert-state "evil-states")
(declare-function evil-normal-state "evil-states")

(defvar-local claude-answer-question nil "The question table this buffer answers.")
(defvar-local claude-answer--chosen nil "Indexes of the chosen options.")
(defvar-local claude-answer--reply-start nil "Marker where the free-text area begins, or nil.")

(defvar claude-answer-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'claude-answer-submit)
    (define-key map (kbd "C-c C-k") #'claude-answer-cancel)
    map))

(define-derived-mode claude-answer-mode text-mode "Claude-Answer"
  "Answer a Claude question; C-c C-c sends it, C-c C-k cancels.")

(with-eval-after-load 'evil
  (evil-define-key '(normal motion) claude-answer-mode-map
    (kbd "RET") #'claude-answer-toggle
    (kbd "SPC") #'claude-answer-toggle
    (kbd "x") #'claude-answer-toggle
    (kbd "n") #'claude-answer-next-option
    (kbd "j") #'claude-answer-next-option
    (kbd "p") #'claude-answer-previous-option
    (kbd "k") #'claude-answer-previous-option
    (kbd "q") #'claude-answer-cancel))

(defun claude-answer--options (question)
  (append (gethash "options" question) nil))

(defun claude-answer--dim (string)
  (propertize string 'font-lock-face 'claude-dashboard-dim))

(defun claude-answer--box (index)
  "The checkbox text for option INDEX."
  (let ((on (memq index claude-answer--chosen)))
    (if (eq (gethash "multiple" claude-answer-question) t)
        (if on "[x]" "[ ]")
      (if on "(x)" "( )"))))

(defun claude-answer--insert-option (index option)
  (insert (propertize (format "%s %s\n" (claude-answer--box index) option)
                      'claude-answer-option index)))

(defun claude-answer--fill (question)
  "Draw QUESTION into the current buffer, leaving only the reply area editable."
  (let ((inhibit-read-only t)
        (options (claude-answer--options question))
        (blocks (gethash "blocks" question ""))
        (asker (gethash "asker" question "")))
    (erase-buffer)
    (insert (propertize (concat (gethash "text" question) "\n")
                        'font-lock-face 'magit-section-heading))
    (let ((note (string-join (delq nil (list (and (not (equal blocks "")) (format "%s" blocks))
                                             (and (not (equal asker "")) (format "%s" asker))))
                             " ")))
      (unless (string-empty-p note)
        (insert (claude-answer--dim (concat note "\n")))))
    (insert "\n")
    (let ((index 0))
      (dolist (option options)
        (claude-answer--insert-option index option)
        (setq index (1+ index))))
    (when options (insert "\n"))
    (add-text-properties (point-min) (point) '(read-only t front-sticky t))
    (when (or (null options) (eq (gethash "free_text" question) t))
      (let ((start (point)))
        (insert (claude-answer--dim "-- reply (C-c C-c to send, C-c C-k to cancel) --\n"))
        ;; Read-only, but typing right after it is allowed
        (add-text-properties start (point) '(read-only t rear-nonsticky t front-sticky (read-only)))
        (setq claude-answer--reply-start (copy-marker (point)))))))

;;;###autoload
(defun claude-answer-open (question)
  "Show the QUESTION table in a focused window below the selected one."
  (let* ((id (gethash "id" question))
         (buffer (get-buffer-create (format "*claude answer %s*" id))))
    (with-current-buffer buffer
      (claude-answer-mode)
      (setq claude-answer-question question
            claude-answer--chosen nil
            claude-answer--reply-start nil)
      (claude-answer--fill question)
      (if claude-answer--reply-start
          (goto-char (point-max))
        (goto-char (point-min))
        (claude-answer-next-option)))
    (pop-to-buffer buffer '(display-buffer-below-selected (window-height . 0.33)))
    (when (fboundp 'evil-insert-state)
      (if claude-answer--reply-start (evil-insert-state) (evil-normal-state)))
    buffer))

(defun claude-answer--option-index ()
  (get-text-property (line-beginning-position) 'claude-answer-option))

(defun claude-answer-toggle ()
  "Toggle the option on this line (single-choice questions pick just this one)."
  (interactive)
  (let ((index (claude-answer--option-index)))
    (unless index (user-error "Not on an option"))
    (setq claude-answer--chosen
          (cond ((memq index claude-answer--chosen) (delq index claude-answer--chosen))
                ((eq (gethash "multiple" claude-answer-question) t) (cons index claude-answer--chosen))
                (t (list index))))
    (let ((inhibit-read-only t)
          (line (line-number-at-pos)))
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (when-let* ((i (claude-answer--option-index)))
            (let ((box (claude-answer--box i)))
              (unless (string= box (buffer-substring (point) (+ (point) 3)))
                (delete-region (point) (+ (point) 3))
                (insert (propertize box 'claude-answer-option i 'read-only t 'front-sticky t)))))
          (forward-line 1)))
      (goto-char (point-min))
      (forward-line (1- line)))))

(defun claude-answer--move-option (step)
  (let ((here (point)))
    (forward-line step)
    (while (and (not (bobp)) (not (eobp)) (not (claude-answer--option-index)))
      (forward-line step))
    (unless (claude-answer--option-index)
      (goto-char here))))

(defun claude-answer-next-option ()
  "Move to the next option line."
  (interactive)
  (claude-answer--move-option 1))

(defun claude-answer-previous-option ()
  "Move to the previous option line."
  (interactive)
  (claude-answer--move-option -1))

(defun claude-answer--close ()
  (let ((buffer (current-buffer)))
    (if (get-buffer-window buffer)
        (quit-window t)
      (kill-buffer buffer))))

(defun claude-answer-cancel ()
  "Close the window without recording an answer."
  (interactive)
  (claude-answer--close))

(defun claude-answer-submit ()
  "Record the answer, close the window and refresh the dashboard."
  (interactive)
  (let* ((question claude-answer-question)
         (options (claude-answer--options question))
         (choices (mapcar (lambda (i) (nth i options)) (sort (copy-sequence claude-answer--chosen) #'<)))
         (text (if claude-answer--reply-start
                   (string-trim (buffer-substring-no-properties claude-answer--reply-start (point-max)))
                 ""))
         (output (generate-new-buffer " *claude-question*")))
    (when (and options (null choices))
      (user-error "Pick an option first"))
    (when (and options (cdr choices) (not (eq (gethash "multiple" question) t)))
      (user-error "Pick exactly one option"))
    (unwind-protect
        (if (zerop (apply #'call-process claude-dashboard-question-program nil output nil
                          "answer" (gethash "id" question) "--text" text
                          (mapcan (lambda (c) (list "--choice" c)) choices)))
            (progn
              (claude-answer--close)
              (when-let* ((dash (get-buffer "*claude dashboard*")))
                (with-current-buffer dash (claude-dashboard-refresh))))
          (message "%s" (string-trim (with-current-buffer output (buffer-string)))))
      (kill-buffer output))))

(provide 'claude-answer)
;;; claude-answer.el ends here
