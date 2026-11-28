;;; claude-todos.el --- Session todos: a shared Org list beside the session -*- lexical-binding: t; -*-

;; One Org file per main session in `claude-todos-dir', named by session id.
;; The manager writes it directly (TODO/DONE headings, notes under them); the user opens it
;; in a side window with `claude-todos', edits and saves it.  The buffer
;; auto-reverts, so the manager's writes show at once; the manager reads the file, so the user's
;; saved edits reach it.  Agents tied to a heading are written in by the
;; claude-task-links script (see claude-links.el).

(require 'claude)
(require 'org)
(require 'autorevert)
(require 'tab-line)
(require 'homun-layout)
(declare-function claude-links-open-agent "claude-links")

(defvar claude-todos-dir (expand-file-name "~/claude/.services/session-todos/")
  "Where the session todo files are, one SESSION-ID.org each.")


(defun claude-todos-file ()
  "The todo file of the main session."
  (let ((id (claude-main-session-id)))
    (expand-file-name (concat (or id "current") ".org")
                      claude-todos-dir)))

;;; The sorted view

(defconst claude-todos-view-name "*claude todos*" "Name of the sorted, read-only todo view.")

(defconst claude-todos--rank '(("STRT" . 0) ("WAIT" . 1) ("TODO" . 2))
  "Sort rank of the open keywords; any other open keyword comes after them.")

(defvar-local claude-todos--source nil "In the view: the buffer visiting the todo file.")
(defvar-local claude-todos--timer nil "In the source: pending refresh of the view.")

(defun claude-todos--chunks ()
  "The current buffer as (SECTION . ITEMS): level-1 headings and their level-2
subtrees.
SECTION is the text up to the first child, ITEMS are (KEYWORD . TEXT) pairs."
  (let (chunks)
    (save-excursion
      (goto-char (point-min))
      (let ((pre (buffer-substring (point-min) (if (re-search-forward "^\\* " nil t)
                                                    (line-beginning-position)
                                                  (point-max)))))
        (push (list pre) chunks))
      (goto-char (point-min))
      (while (re-search-forward "^\\* " nil t)
        (let* ((start (line-beginning-position))
               (end (save-excursion (if (re-search-forward "^\\* " nil t)
                                        (line-beginning-position) (point-max))))
               (head-end (save-excursion (goto-char start) (forward-line 1)
                                         (if (re-search-forward "^\\*\\* " end t)
                                             (line-beginning-position) end)))
               (chunk (list (buffer-substring start head-end))))
          (goto-char head-end)
          (while (re-search-forward "^\\*\\* \\([A-Z]+\\)?" end t)
            (let ((istart (line-beginning-position)) (key (match-string 1)))
              (end-of-line)
              (let ((iend (if (re-search-forward "^\\*\\* " end t) (line-beginning-position) end)))
                (setq chunk (append chunk (list (cons key (buffer-substring istart iend)))))
                (goto-char iend)
                (when (< iend end) (forward-line 0)))))
          (push chunk chunks)
          (goto-char end))))
    (nreverse chunks)))

(defun claude-todos--sorted (items)
  "ITEMS without the DONE ones, open ones sorted STRT, WAIT, TODO, others; stable."
  (let ((open (seq-remove (lambda (i) (equal (car i) "DONE")) items)))
    (sort open (lambda (a b) (< (or (alist-get (car a) claude-todos--rank nil nil #'equal) 3)
                                (or (alist-get (car b) claude-todos--rank nil nil #'equal) 3))))))

(defun claude-todos--demote (text)
  "TEXT with every heading one level deeper."
  (replace-regexp-in-string "^\\*" "**" text))

(defun claude-todos--done-open (view)
  "Names of the sections of VIEW whose Done line is unfolded now."
  (with-current-buffer view
    (let (names)
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward "^\\*\\* Done ([0-9]+)" nil t)
          (unless (org-fold-folded-p (line-end-position))
            (push (claude-todos--section-name) names))))
      names)))

(defun claude-todos--render (view)
  "Rebuild VIEW from its source buffer: open items sorted, DONE ones folded."
  (let ((chunks (with-current-buffer (buffer-local-value 'claude-todos--source view)
                  (claude-todos--chunks)))
        (open (claude-todos--done-open view)) (hide '()) (line 0))
    (with-current-buffer view
      (let ((inhibit-read-only t) (pos (point)))
        (erase-buffer)
        (claude-touch)
        (insert (caar chunks))
        (dolist (chunk (cdr chunks))
          (let* ((items (cdr chunk))
                 (done (seq-filter (lambda (i) (equal (car i) "DONE")) items))
                 (name (string-trim (car (split-string (car chunk) "\n")) "\\* *")))
            (insert (car chunk))
            (dolist (i (claude-todos--sorted items)) (insert (cdr i)))
            (when done
              (setq line (point))
              (insert (format "** Done (%d)\n" (length done)))
              (unless (member name open) (push line hide))
              (dolist (i done) (insert (claude-todos--demote (cdr i)))))))
        (org-content)
        (org-fold-hide-drawer-all)
        (dolist (p hide) (save-excursion (goto-char p) (org-fold-subtree t)))
        (goto-char (min pos (point-max)))))))

(defun claude-todos--done-heading-p ()
  "Non-nil when point is on a \"Done (N)\" heading."
  (save-excursion (beginning-of-line) (looking-at "\\*\\* Done ([0-9]+)")))

(defun claude-todos--section-name ()
  "The name of the level-1 section around point."
  (save-excursion (when (org-up-heading-safe) (org-get-heading t t t t))))

(defun claude-todos-view-toggle ()
  "Expand or collapse the item at point; the Done fold survives redraws."
  (interactive)
  (org-cycle))

(defun claude-todos-view-click (event)
  "Plain click on a Done line toggles it."
  (interactive "e")
  (mouse-set-point event)
  (org-cycle))

(defun claude-todos-view-edit ()
  "Open the agent of the heading at point, else visit the todo file at the heading."
  (interactive)
  (if-let* ((link (org-entry-get nil "AGENT"))
            ((string-match "homun-agent:\\([^]]+\\)\\]" link)))
      (claude-links-open-agent (match-string 1 link))
    (claude-todos--visit)))

(defun claude-todos--visit ()
  "Visit the todo file at the heading of the item at point."
  (let ((heading (org-get-heading t t t t)))
    (pop-to-buffer claude-todos--source)
    (goto-char (point-min))
    (when (and heading (search-forward heading nil t)) (beginning-of-line))))

(defvar-keymap claude-todos-view-mode-map
  :doc "Keys of the sorted todo view."
  "TAB" #'claude-todos-view-toggle
  "<mouse-1>" #'claude-todos-view-click
  "RET" #'claude-todos-view-edit)

(define-derived-mode claude-todos-view-mode org-mode "Todos"
  "Read-only, sorted view of the session's todo file; DONE items fold under
Done (N)."
  (setq buffer-read-only t)
  (setq-local display-line-numbers nil
              header-line-format (claude-header "Todos" "TAB fold · RET open the agent or the file")))

(defun claude-todos--refresh (source)
  "Rebuild the view of SOURCE if it exists."
  (when-let* ((view (get-buffer claude-todos-view-name)))
    (when (and (buffer-live-p source) (eq (buffer-local-value 'claude-todos--source view) source))
      (claude-todos--render view))))

(defun claude-todos--schedule ()
  "Refresh the view soon after the source changed."
  (let ((source (current-buffer)))
    (unless claude-todos--timer
      (setq claude-todos--timer
            (run-with-idle-timer 0.2 nil
                                 (lambda ()
                                   (when (buffer-live-p source)
                                     (with-current-buffer source (setq claude-todos--timer nil))
                                     (claude-todos--refresh source))))))))

(defun claude-todos--view (source)
  "The sorted view of SOURCE, created and filled when missing."
  (let ((view (get-buffer-create claude-todos-view-name)))
    (with-current-buffer view
      (unless (derived-mode-p 'claude-todos-view-mode) (claude-todos-view-mode))
      (setq claude-todos--source source)
      (claude-todos--render view))
    (with-current-buffer source
      (add-hook 'after-change-functions (lambda (&rest _) (claude-todos--schedule)) nil t)
      (add-hook 'after-revert-hook #'claude-todos--schedule nil t))
    view))

;;; The cockpit's right side window and its tabs

(defun claude-todos--tabs ()
  "The cockpit buffers that exist, as tabs.
Todos, the agent view, pending questions and review notes."
  (let ((todos (get-buffer claude-todos-view-name)))
    (delq nil (append (list todos)
                      (and (fboundp 'claude-questions--pending) (claude-questions--pending))
                      (seq-filter (lambda (b) (string-prefix-p "*claude review notes " (buffer-name b)))
                                  (buffer-list))))))

(defun claude-todos-tab-next (&optional n)
  "Show the Nth next cockpit buffer (previous when negative) in the side window."
  (interactive "p")
  (let* ((window (or (homun-layout-window 'stage) (get-buffer-window claude-todos-view-name)
                     (user-error "No cockpit side window")))
         (tabs (claude-todos--tabs))
         (pos (or (seq-position tabs (window-buffer window)) 0)))
    (when tabs
      (homun-layout-show (nth (mod (+ pos (or n 1)) (length tabs)) tabs) window))))

(defun claude-todos-tab-previous (&optional n)
  "Show the Nth previous cockpit buffer in the side window."
  (interactive "p")
  (claude-todos-tab-next (- (or n 1))))

;;;###autoload
(defun claude-todos ()
  "Show the main session's todos in a side window on the right."
  (interactive)
  (let* ((file (claude-todos-file))
         (buffer (progn (make-directory (file-name-directory file) t)
                        (find-file-noselect file))))
    (with-current-buffer buffer
      ;; The manager's writes show at once (file notification); auto-revert never
      ;; overwrites unsaved edits of the user's
      (setq-local auto-revert-verbose nil)
      (auto-revert-mode 1)
      ;; An agent that failed leaves its heading FAILED (claude-links)
      (unless (member "FAILED" org-todo-keywords-1)
        (setq-local org-todo-keywords (append org-todo-keywords '((sequence "|" "FAILED"))))
        (org-set-regexps-and-options)
        (font-lock-flush)))
    (homun-layout-side (claude-todos--view buffer) t)))

(provide 'claude-todos)
;;; claude-todos.el ends here
