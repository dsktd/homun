;;; claude-follow.el --- Watch what Claude sessions edit -*- lexical-binding: t -*-

;; `M-x claude-follow' lists the files every session and subagent edited, from
;; the one-line-per-edit logs container/follow-hook.sh writes to
;; ~/claude/.services/follow/<session>.jsonl (paths only, no contents; a
;; session's log goes away when it ends). A file-notify watch on that directory
;; keeps the buffer current and says what changed in the echo area. No model is
;; involved. Only paths under ~/claude are read, so a host Emacs can use it too.

(require 'cl-lib)
(require 'filenotify)
(require 'json)
(require 'magit-section)
(require 'pulse)
(require 'seq)
(require 'subr-x)

(defvar claude-follow-dir
  (or (getenv "CLAUDE_FOLLOW_DIR") (expand-file-name "~/claude/.services/follow"))
  "Where the hook writes <session>.jsonl.")
(defvar claude-follow-max-entries 500
  "Edits kept in memory; the oldest are dropped first.")

(defvar claude-follow-auto t
  "When non-nil, a new edit refreshes the worktree's Magit buffers, diff-hl and
the file's buffer, without selecting or raising anything.")

(defcustom claude-follow-display 'file
  "What an agent's new edit shows in a GUI frame while auto-follow is on.
`file' is the edited file at its first changed hunk, `diff' Magit's diff of it,
nil nothing. A commit entry shows the commit unless this is nil."
  :type '(choice (const file) (const diff) (const nil))
  :group 'tools)

(defvar claude-follow--entries nil
  "The edits, newest first, as plists (:ts :session :agent :tool :file :worktree).")
(defvar claude-follow--watch nil)

(defun claude-follow--read-file (path)
  "The edits in the log PATH; lines that do not parse are skipped."
  (let (rows)
    (with-temp-buffer
      (insert-file-contents path)
      (dolist (line (split-string (buffer-string) "\n" t))
        (when-let* ((row (ignore-errors (json-parse-string line :object-type 'plist))))
          (push (list :ts (or (plist-get row :ts) 0)
                      :session (or (plist-get row :session_id) "?")
                      :agent (or (plist-get row :agent) "main")
                      :agent_type (or (plist-get row :agent_type) "")
                      :tool (or (plist-get row :tool) "")
                      :file (or (plist-get row :file) "")
                      :worktree (or (plist-get row :worktree) "")
                      :commit (or (plist-get row :commit) "")
                      :cwd (or (plist-get row :cwd) ""))
                rows))))
    rows))

(defun claude-follow--read ()
  "All edits from the log directory, newest first, at most the cap."
  (let (rows)
    (dolist (path (and (file-directory-p claude-follow-dir)
                       (directory-files claude-follow-dir t "\\.jsonl\\'")))
      (setq rows (nconc (ignore-errors (claude-follow--read-file path)) rows)))
    (seq-take (sort rows (lambda (a b) (> (plist-get a :ts) (plist-get b :ts))))
              claude-follow-max-entries)))

(defun claude-follow--new (old new)
  "Edits in NEW that OLD does not have, newest first."
  (seq-remove (lambda (e) (member e old)) new))

(defun claude-follow--group (entries key)
  "ENTRIES (newest first) as an alist of (KEY-VALUE . ENTRIES), newest group first."
  (let (groups)
    (dolist (e entries)
      (let* ((k (plist-get e key)) (cell (assoc k groups)))
        (if cell (setcdr cell (cons e (cdr cell))) (push (list k e) groups))))
    (nreverse (mapcar (lambda (g) (cons (car g) (nreverse (cdr g)))) groups))))

(defun claude-follow--time (ts)
  "TS (epoch seconds) as HH:MM:SS."
  (format-time-string "%H:%M:%S" ts))

(defun claude-follow--relative (file worktree)
  "FILE relative to WORKTREE when it is under it."
  (if (and (not (string-empty-p worktree)) (string-prefix-p (file-name-as-directory worktree) file))
      (file-relative-name file worktree)
    (abbreviate-file-name file)))

;; A file section's value is (FILE WORKTREE COMMIT); COMMIT is nil for an edit,
;; and "" for an older git row that has no commit id.
(defun claude-follow--commit (entry)
  "The commit of ENTRY when it comes from git, else nil."
  (and (equal (plist-get entry :tool) "commit") (plist-get entry :commit)))

(defun claude-follow--insert-worktree (worktree entries)
  "Insert the section of WORKTREE with one line per file of ENTRIES."
  (magit-insert-section (claude-follow-worktree worktree)
    (magit-insert-heading
      "    "
      (propertize (if (string-empty-p worktree) "(no repository)" (abbreviate-file-name worktree))
                  'font-lock-face 'magit-branch-local)
      (format " (%d)" (length (claude-follow--group entries :file))))
    (dolist (group (claude-follow--group entries :file))
      (let ((latest (cadr group)))
        (magit-insert-section (claude-follow-file (list (car group) worktree (claude-follow--commit latest)))
          (insert "      "
                  (propertize (claude-follow--time (plist-get latest :ts)) 'font-lock-face 'shadow)
                  "  "
                  (if-let* ((commit (claude-follow--commit latest)))
                      (propertize (format "%-7.7s  " commit) 'font-lock-face 'shadow)
                    "")
                  (claude-follow--relative (car group) worktree)
                  (if (cddr group) (propertize (format "  x%d" (length (cdr group))) 'font-lock-face 'shadow) "")
                  "\n"))))
    (insert "\n")))

(defvar claude-follow-manager-session-file "~/.claude/manager-session"
  "File holding the session id of the pinned Manager session.")

(defvar claude-follow-manager-name "Tally"
  "What the pinned Manager session and its own edits are called.")

(defun claude-follow--manager-p (session)
  "Non-nil when SESSION is the pinned Manager session."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents (expand-file-name claude-follow-manager-session-file))
      (equal (string-trim (buffer-string)) session))))

(defun claude-follow--main-p (agent)
  "Non-nil when AGENT names a session's own, not a subagent's, edits."
  (member agent '("claude" "main")))

(defun claude-follow--workspace (entries)
  "The workspace a session runs in, from the oldest of ENTRIES (newest first) that has a cwd.
That is the directory under ~/claude (~/claude/<workspace>/<repo>), else the
cwd's own name; nil for ~/claude itself."
  (when-let* ((cwd (seq-some (lambda (e) (let ((c (plist-get e :cwd))) (and (not (string-empty-p c)) c)))
                             (reverse entries)))
              (root (file-name-as-directory (expand-file-name "~/claude")))
              (dir (file-name-as-directory (expand-file-name cwd))))
    (cond ((equal dir root) nil)
          ((string-prefix-p root dir) (car (split-string (substring dir (length root)) "/" t)))
          (t (file-name-nondirectory (directory-file-name dir))))))

(defun claude-follow--insert-session (session entries)
  "Insert the section of SESSION, one subsection per agent and worktree."
  (magit-insert-section (claude-follow-session session)
    (magit-insert-heading
      (if (claude-follow--manager-p session)
          (propertize claude-follow-manager-name 'font-lock-face 'magit-section-heading)
        (concat (propertize "Session " 'font-lock-face 'magit-section-heading)
                (substring session 0 (min 8 (length session)))))
      (if-let* ((ws (claude-follow--workspace entries)))
          (propertize (format "  %s" ws) 'font-lock-face 'magit-branch-local)
        "")
      (propertize (format "  last %s" (claude-follow--time (plist-get (car entries) :ts)))
                  'font-lock-face 'shadow))
    (dolist (agent (claude-follow--group entries :agent))
      (magit-insert-section (claude-follow-agent (car agent))
        (magit-insert-heading
          "  "
          (let ((type (plist-get (cadr agent) :agent_type)))
            (cond ((claude-follow--main-p (car agent))
                   (propertize "own edits" 'font-lock-face 'magit-section-secondary-heading))
                  (t (concat (propertize (if (string-empty-p type) "agent" type)
                                         'font-lock-face 'magit-section-secondary-heading)
                             (propertize (format "  %.7s" (car agent)) 'font-lock-face 'shadow))))))
        (dolist (tree (claude-follow--group (cdr agent) :worktree))
          (claude-follow--insert-worktree (car tree) (cdr tree)))))))

(defun claude-follow-refresh ()
  "Read the logs again and redraw, keeping point and folds."
  (interactive)
  (setq claude-follow--entries (claude-follow--read))
  (when-let* ((buffer (get-buffer "*claude-follow*")))
    (with-current-buffer buffer (claude-follow--draw))))

(defun claude-follow--draw ()
  "Redraw the current buffer from `claude-follow--entries'."
  (let* ((section (magit-current-section))
         (position (and section (magit-section-get-relative-position section)))
         (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (claude-follow)
      (insert (propertize (format "Auto-follow: %s\n\n" (if claude-follow-auto "on" "off"))
                          'font-lock-face 'shadow))
      (if (null claude-follow--entries)
          (insert (propertize "No edits recorded.\n" 'font-lock-face 'shadow))
        (dolist (session (claude-follow--group claude-follow--entries :session))
          (claude-follow--insert-session (car session) (cdr session)))))
    (goto-char (point-min))
    (when section
      (apply #'magit-section-goto-successor section position))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))))

(defun claude-follow--file-at-point ()
  "The file of the section at point, or nil."
  (when-let* ((section (magit-current-section)))
    (and (eq (oref section type) 'claude-follow-file) (car (oref section value)))))

(defun claude-follow--commit-at-point ()
  "The commit of the git entry at point (\"\" when unknown), nil for an edit."
  (when-let* ((section (magit-current-section)))
    (and (eq (oref section type) 'claude-follow-file) (nth 2 (oref section value)))))

(defun claude-follow--worktree-at-point ()
  "The worktree of the file or worktree section at point, or nil."
  (when-let* ((section (magit-current-section)))
    (pcase (oref section type)
      ('claude-follow-file (cadr (oref section value)))
      ('claude-follow-worktree (oref section value)))))

(defun claude-follow--show-commit ()
  "Magit's diff of the commit at point for its file, else the file's log."
  (let ((commit (claude-follow--commit-at-point))
        (file (claude-follow--file-at-point)))
    (claude-follow--in-worktree
     (lambda ()
       (let ((relative (file-relative-name file default-directory)))
         (if (string-empty-p commit)
             (magit-log-current nil (list relative))
           (magit-show-commit commit nil (list relative))))))))

(defun claude-follow-visit ()
  "Visit the file at point, or show its commit in Magit; else toggle the section."
  (interactive)
  (if-let* ((file (claude-follow--file-at-point)))
      (if (claude-follow--commit-at-point)
          (claude-follow--show-commit)
        (pop-to-buffer (find-file-noselect file)))
    (when-let* ((section (magit-current-section)))
      (magit-section-toggle section))))

(defun claude-follow-next-edit ()
  "Move to the next edited file."
  (interactive)
  (forward-line 1)
  (while (and (not (eobp)) (not (claude-follow--file-at-point))) (forward-line 1)))

(defun claude-follow-previous-edit ()
  "Move to the previous edited file."
  (interactive)
  (let ((start (point)))
    (forward-line -1)
    (while (and (not (bobp)) (not (claude-follow--file-at-point))) (forward-line -1))
    (unless (claude-follow--file-at-point) (goto-char start))))

;; Magit shows the diffs; these run it for the worktree at point.
(defun claude-follow--in-worktree (fn)
  "Call FN with `default-directory' the worktree at point."
  (let ((default-directory (or (claude-follow--worktree-at-point)
                               (user-error "No worktree at point"))))
    (when (string-empty-p default-directory) (user-error "Not a repository"))
    (funcall fn)))

(defun claude-follow-diff ()
  "Magit's unstaged diff of the worktree at point (the commit's, for a git entry)."
  (interactive)
  (if (claude-follow--commit-at-point)
      (claude-follow--show-commit)
    (claude-follow--in-worktree #'magit-diff-unstaged)))

(declare-function difftastic-magit-diff "difftastic")
(defun claude-follow-difftastic ()
  "The structural diff (difftastic) of the worktree at point, through Magit."
  (interactive)
  (if (claude-follow--commit-at-point)
      (claude-follow--show-commit)
   (if (and (require 'difftastic nil t) (executable-find "difft"))
      (claude-follow--in-worktree #'difftastic-magit-diff)
    (user-error "Needs the difftastic package and `difft' (nix shell nixpkgs#difftastic)"))))

(defun claude-follow-log ()
  "Magit's log of the current branch of the worktree at point."
  (interactive)
  (claude-follow--in-worktree (lambda () (magit-log-current (list "-n30")))))

(defun claude-follow-toggle-auto ()
  "Turn auto-follow on or off."
  (interactive)
  (setq claude-follow-auto (not claude-follow-auto))
  (when-let* ((buffer (get-buffer "*claude-follow*")))
    (with-current-buffer buffer (claude-follow--draw)))
  (message "claude-follow: auto-follow %s" (if claude-follow-auto "on" "off")))

(defun claude-follow--revert ()
  "Revert the current buffer from disk and flash what changed (goggles' face)."
  (let* ((old (buffer-string))
         (point (point)))
    (revert-buffer t t t)
    (require (quote goggles) nil t)
    (let* ((new (buffer-string))
           (head (let ((c (compare-strings old nil nil new nil nil)))
                   (if (eq c t) (length new) (1- (abs c)))))
           (tail (let ((n 0) (lo (length old)) (ln (length new)))
                   (while (and (< n (- (min lo ln) head))
                               (eq (aref old (- lo n 1)) (aref new (- ln n 1))))
                     (setq n (1+ n)))
                   n)))
      (goto-char (min point (point-max)))
      (when (and (get-buffer-window (current-buffer) t) (< head (- (length new) tail)))
        (let ((pulse-delay 0.05) (pulse-iterations 12))
          (pulse-momentary-highlight-region
           (1+ head) (1+ (- (length new) tail))
           (if (facep 'goggles-changed) 'goggles-changed 'pulse-highlight-start-face)))))))

(defun claude-follow--apply (entry)
  "Bring Emacs up to date with the edit ENTRY, quietly."
  (let ((file (plist-get entry :file))
        (worktree (plist-get entry :worktree))
        (inhibit-message t))
    (ignore-errors
      (unless (string-empty-p worktree)
        (dolist (buffer (magit-mode-get-buffers))
          (with-current-buffer buffer
            (when (equal (magit-toplevel) (file-name-as-directory worktree))
              (magit-refresh-buffer))))))
    (when-let* ((buffer (find-buffer-visiting file)))
      (with-current-buffer buffer
        (ignore-errors
          (unless (buffer-modified-p) (claude-follow--revert))
          (when (bound-and-true-p diff-hl-mode) (diff-hl-update)))))))

;; Showing an edit: one window of the first GUI frame, reused, never raised or selected.
(defvar claude-follow--timer nil)

(defun claude-follow--gui-frame ()
  "The frame where an edit is shown, or nil (also in batch).
That is the frame already showing the follow buffer, GUI or terminal, so a
`emacsclient -t' session works too, else the first GUI frame."
  (and (not noninteractive)
       (or (when-let* ((buffer (get-buffer "*claude-follow*"))
                       (window (get-buffer-window buffer t)))
             (window-frame window))
           (seq-find (lambda (f) (frame-parameter f 'window-system)) (frame-list)))))

(defun claude-follow--display (buffer &rest _)
  "Show BUFFER in the follow window of the GUI frame without selecting it; the window."
  (when-let* ((frame (claude-follow--gui-frame)))
    (with-selected-frame frame
      (let ((window (or (seq-find (lambda (w) (window-parameter w 'claude-follow-display-window))
                                  (window-list frame 'never))
                        (display-buffer buffer '((display-buffer-use-some-window
                                                  display-buffer-pop-up-window)
                                                 (inhibit-same-window . t))))))
        (when window
          (set-window-parameter window 'claude-follow-display-window t)
          (unless (eq (window-buffer window) buffer)
            (set-window-buffer window buffer))
          window)))))

(defun claude-follow--hunk-line (diff)
  "The new-side first line of the first hunk in DIFF (git diff -U0 output), else 1."
  (if (string-match "^@@ -[0-9,]+ \\+\\([0-9]+\\)" diff)
      (max 1 (string-to-number (match-string 1 diff)))
    1))

(defun claude-follow--file-line (file worktree)
  "The first changed line of FILE in WORKTREE; 1 for a new file or on git failure."
  (with-temp-buffer
    (if (and (zerop (ignore-errors
                      (call-process "git" nil t nil "-C" worktree "diff" "-U0" "--no-color"
                                    "--" file)))
             (> (buffer-size) 0))
        (claude-follow--hunk-line (buffer-string))
      1)))

(defun claude-follow--show-file (file worktree)
  "Show FILE reverted from disk with its follow window's point on the first change."
  (let ((buffer (find-file-noselect file)))
    (with-current-buffer buffer
      (unless (buffer-modified-p) (revert-buffer t t t)))
    (when-let* ((window (claude-follow--display buffer)))
      (with-current-buffer buffer
        (save-excursion
          (goto-char (point-min))
          (forward-line (1- (claude-follow--file-line file worktree)))
          (set-window-point window (point))
          (let ((pulse-delay 0.05) (pulse-iterations 12))
            (pulse-momentary-highlight-one-line
             (point) (if (facep 'goggles-changed) 'goggles-changed 'pulse-highlight-start-face))))))))

(defun claude-follow--show-magit (fn &rest args)
  "Call the Magit command FN with ARGS, displaying its buffer without selecting it."
  (let ((magit-display-buffer-noselect t)
        (magit-display-buffer-function #'claude-follow--display))
    (apply fn args)))

(defun claude-follow--show (entry)
  "Show the edit ENTRY as `claude-follow-display' says; nothing without a GUI frame."
  (let* ((file (plist-get entry :file))
         (worktree (plist-get entry :worktree))
         (commit (claude-follow--commit entry))
         (default-directory (if (string-empty-p worktree) default-directory
                              (file-name-as-directory worktree)))
         (rel (file-relative-name file default-directory)))
    (when (and claude-follow-display (claude-follow--gui-frame))
      (ignore-errors
        (cond ((and commit (not (string-empty-p commit)))
               (claude-follow--show-magit #'magit-show-commit commit nil (list rel)))
              (commit nil)
              ((eq claude-follow-display 'diff)
               (claude-follow--show-magit #'magit-diff-unstaged nil (list rel))
               (when-let* ((window (get-buffer-window (magit-get-mode-buffer 'magit-diff-mode) t)))
                 (with-current-buffer (window-buffer window)
                   (save-excursion
                     (goto-char (point-min))
                     (when (re-search-forward (concat "^[a-z ]+ +" (regexp-quote rel) "$") nil t)
                       (set-window-point window (line-beginning-position)))))))
              (t (claude-follow--show-file file worktree)))))))

(defun claude-follow--show-later (entry)
  "Show ENTRY after a second; a newer edit in that time replaces it."
  (when (timerp claude-follow--timer) (cancel-timer claude-follow--timer))
  (setq claude-follow--timer (run-with-timer 1 nil #'claude-follow--show entry)))

(defun claude-follow-cycle-display ()
  "Cycle `claude-follow-display' through file, diff and nil."
  (interactive)
  (setq claude-follow-display (pcase claude-follow-display ('file 'diff) ('diff nil) (_ 'file)))
  (message "claude-follow: display %s" (or claude-follow-display "off")))

(defvar claude-follow-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "g") #'claude-follow-refresh)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "RET") #'claude-follow-visit)
    (define-key map (kbd "n") #'claude-follow-next-edit)
    (define-key map (kbd "p") #'claude-follow-previous-edit)
    (define-key map (kbd "d") #'claude-follow-diff)
    (define-key map (kbd "D") #'claude-follow-difftastic)
    (define-key map (kbd "l") #'claude-follow-log)
    (define-key map (kbd "f") #'claude-follow-toggle-auto)
    (define-key map (kbd "v") #'claude-follow-cycle-display)
    map))

(define-derived-mode claude-follow-mode magit-section-mode "Claude-Follow"
  "The files Claude sessions and their subagents edited, by session and worktree.")

(declare-function evil-define-key "evil-core")
(with-eval-after-load 'evil
  (evil-define-key '(normal motion) claude-follow-mode-map
    (kbd "gr") #'claude-follow-refresh
    (kbd "q") #'quit-window
    (kbd "RET") #'claude-follow-visit
    (kbd "TAB") #'magit-section-toggle
    (kbd "n") #'claude-follow-next-edit
    (kbd "p") #'claude-follow-previous-edit
    (kbd "d") #'claude-follow-diff
    (kbd "D") #'claude-follow-difftastic
    (kbd "l") #'claude-follow-log
    (kbd "f") #'claude-follow-toggle-auto
    (kbd "v") #'claude-follow-cycle-display))

(defun claude-follow--changed (&optional _event)
  "The watch fired: read the logs, say what is new, redraw."
  (let* ((old claude-follow--entries)
         (new (claude-follow--read))
         (fresh (claude-follow--new old new)))
    (setq claude-follow--entries new)
    (when-let* ((buffer (get-buffer "*claude-follow*")))
      (with-current-buffer buffer (claude-follow--draw)))
    (when claude-follow-auto
      (mapc #'claude-follow--apply (seq-uniq fresh (lambda (a b) (equal (plist-get a :file) (plist-get b :file)))))
      (when fresh (claude-follow--show-later (car fresh))))
    (when-let* ((e (car fresh)))
      (message "claude-follow: %s edited %s" (plist-get e :agent)
               (file-name-nondirectory (plist-get e :file))))))

(defun claude-follow--watch ()
  "Watch the log directory once."
  (make-directory claude-follow-dir t)
  (unless (and claude-follow--watch (file-notify-valid-p claude-follow--watch))
    (setq claude-follow--watch
          (file-notify-add-watch claude-follow-dir '(change) #'claude-follow--changed))))

(defun claude-follow--agent-entries (name type)
  "Edits by the agent called NAME or of agent type TYPE (either may be nil)."
  (seq-filter (lambda (e)
                (or (equal (plist-get e :agent) name)
                    (and (equal name claude-follow-manager-name)
                         (claude-follow--main-p (plist-get e :agent))
                         (claude-follow--manager-p (plist-get e :session)))
                    (equal (plist-get e :agent_type) name)
                    (and type (equal (plist-get e :agent_type) type))))
              (claude-follow--read)))

(defun claude-follow-agent-count (name type)
  "How many edits the agent NAME / TYPE has in the logs."
  (length (claude-follow--agent-entries name type)))

(defun claude-follow-show-agent (name type)
  "Open the follow buffer on the latest edit of the agent NAME / TYPE.
Says so in the echo area when it has none."
  (let ((latest (car (claude-follow--agent-entries name type))))
    (pop-to-buffer (claude-follow))
    (if (not latest)
        (message "claude-follow: no edits recorded for %s" name)
      (let ((found (claude-follow--find-agent (plist-get latest :session) (plist-get latest :agent))))
        (if (not found)
            (message "claude-follow: no edits recorded for %s" name)
          (magit-section-show found)
          (goto-char (oref found start))
          (claude-follow-next-edit))))))

(defun claude-follow--find-agent (session agent)
  "The agent section for AGENT within SESSION's section, or nil."
  (cl-labels ((walk (section)
                (if (and (eq (oref section type) 'claude-follow-agent)
                         (equal (oref section value) agent)
                         (equal (oref (oref section parent) value) session))
                    section
                  (seq-some #'walk (oref section children)))))
    (walk magit-root-section)))

;;;###autoload
(defun claude-follow ()
  "Show the edits of every Claude session, kept current while Emacs runs."
  (interactive)
  (let ((buffer (get-buffer-create "*claude-follow*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'claude-follow-mode) (claude-follow-mode)))
    (unless noninteractive (claude-follow--watch))
    (claude-follow-refresh)
    (if noninteractive (set-buffer buffer) (switch-to-buffer buffer))
    buffer))

(provide 'claude-follow)

;;; claude-follow.el ends here
