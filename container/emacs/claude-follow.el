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
                      :commit (or (plist-get row :commit) ""))
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

(defun claude-follow--insert-session (session entries)
  "Insert the section of SESSION, one subsection per agent and worktree."
  (magit-insert-section (claude-follow-session session)
    (magit-insert-heading
      (if (claude-follow--manager-p session)
          (propertize claude-follow-manager-name 'font-lock-face 'magit-section-heading)
        (concat (propertize "Session " 'font-lock-face 'magit-section-heading)
                (substring session 0 (min 8 (length session)))))
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
  (claude-follow--draw)
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
    (kbd "f") #'claude-follow-toggle-auto))

(defun claude-follow--changed (&optional _event)
  "The watch fired: read the logs, say what is new, redraw."
  (let* ((old claude-follow--entries)
         (new (claude-follow--read))
         (fresh (claude-follow--new old new)))
    (setq claude-follow--entries new)
    (when-let* ((buffer (get-buffer "*claude-follow*")))
      (with-current-buffer buffer (claude-follow--draw)))
    (when claude-follow-auto
      (mapc #'claude-follow--apply (seq-uniq fresh (lambda (a b) (equal (plist-get a :file) (plist-get b :file))))))
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
