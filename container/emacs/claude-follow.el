;;; claude-follow.el --- Watch what Claude sessions edit -*- lexical-binding: t -*-

;; `M-x claude-follow' lists the files every session and subagent edited, from
;; the one-line-per-edit logs container/follow-hook.sh writes to
;; ~/claude/.services/follow/<session>.jsonl (paths only, no contents; a
;; session's log goes away when it ends). A file-notify watch on that directory
;; keeps the buffer current and says what changed in the echo area. No model is
;; involved. Only paths under ~/claude are read, so a host Emacs can use it too, but
;; the git config of the followed repositories is container-controlled, so a host
;; Emacs must not auto-follow them.

(require 'cl-lib)
(require 'filenotify)
(require 'json)
(require 'magit-section)
(require 'pulse)
(require 'seq)
(require 'subr-x)

;; Magit is autoloaded on first use, so these must be known as dynamic here
;; for the let-bindings in `claude-follow--show-magit' to reach it.
(defvar magit-display-buffer-function)
(defvar magit-display-buffer-noselect)

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
(defvar claude-follow--archive nil
  "The archived edits (see `claude-follow--archived-p'), newest first.")
(defvar claude-follow--watch nil)

(defvar claude-follow-archive-after (* 6 3600)
  "Seconds after its newest edit that a project moves to the Archive.")
(defvar claude-follow-archive-max-entries 300
  "The most archived edits kept.")
(defvar claude-follow--dones nil "The `done' marker rows as of the last read.")

;; Hiding archives, never deletes: a key (see `claude-follow--keys') maps to the
;; time it was hidden, and edits at or before that go to the Archive.
(defvar claude-follow--hidden nil
  "Alist of (KEY . TIME): edits of KEY logged at or before TIME are archived.")

;; The logs are data: a row is kept only when its ts is a number and its file a
;; string, any other field that is not a string takes its default, and a commit
;; counts only as a hex id (it is given to git as a revision).
(defun claude-follow--string (row key default)
  "The string under KEY in the parsed ROW, else DEFAULT."
  (let ((value (plist-get row key)))
    (if (stringp value) value default)))

(defun claude-follow--home-part (file)
  "The first path component of FILE under $HOME when FILE is there but outside ~/claude, else nil."
  (let* ((home (file-name-as-directory (expand-file-name "~")))
         (path (expand-file-name file))
         (claude (file-name-as-directory (expand-file-name "~/claude"))))
    (when (and (string-prefix-p home path) (not (string-prefix-p claude path)))
      (car (split-string (substring path (length home)) "/" t)))))

(defun claude-follow--tmp-parts (file)
  "The path components of FILE below /tmp/ when it is there, else nil."
  (let ((path (expand-file-name file)))
    (when (string-prefix-p "/tmp/" path)
      (split-string (substring path 5) "/" t))))

(defun claude-follow--workspace-of (file)
  "The workspace of FILE: its first directory under ~/claude; \"dotfiles\" for what is
under $HOME outside ~/claude; else its top directory (tmp for /tmp).  A file directly in ~/claude
belongs to the workspace \"claude\"."
  (let* ((root (file-name-as-directory (expand-file-name "~/claude")))
         (path (expand-file-name file))
         (parts (split-string (if (string-prefix-p root path) (substring path (length root)) path)
                              "/" t)))
    (cond ((claude-follow--home-part file) "dotfiles")
          ((cdr parts) (car parts))
          (t "claude"))))

(defun claude-follow--project-of (file worktree)
  "The project of FILE, always a path: its WORKTREE; the first component under $HOME;
the first directory below /tmp; under ~/claude the first directory below the
workspace (the workspace folder for a file directly in it); else its parent directory."
  (let* ((root (file-name-as-directory (expand-file-name "~/claude")))
         (path (expand-file-name file))
         (parts (and (string-prefix-p root path) (split-string (substring path (length root)) "/" t))))
    (cond ((not (string-empty-p worktree)) worktree)
          ((claude-follow--home-part file) (expand-file-name (claude-follow--home-part file) "~"))
          ((cdr (claude-follow--tmp-parts file))
           (concat "/tmp/" (car (claude-follow--tmp-parts file))))
          ((cddr parts) (concat root (car parts) "/" (cadr parts)))
          (parts (directory-file-name (concat root (if (cdr parts) (car parts) ""))))
          (t (directory-file-name (file-name-directory path))))))

(defun claude-follow--entry (row)
  "The edit the parsed log ROW describes, or nil when it has no usable ts or file."
  (let ((ts (plist-get row :ts))
        (commit (claude-follow--string row :commit "")))
    (when (and (numberp ts) (stringp (plist-get row :file)))
      (list :ts ts
            :session (claude-follow--string row :session_id "?")
            :agent (claude-follow--string row :agent "main")
            :agent_type (claude-follow--string row :agent_type "")
            :tool (claude-follow--string row :tool "")
            :file (plist-get row :file)
            :workspace (claude-follow--workspace-of (plist-get row :file))
            :kind (claude-follow--kind (plist-get row :file))
            :worktree (claude-follow--string row :worktree "")
            :project (claude-follow--project-of (plist-get row :file)
                                                (claude-follow--string row :worktree ""))
            :commit (if (string-match-p "\\`[0-9a-f]\\{7,40\\}\\'" commit) commit "")
            :cwd (claude-follow--string row :cwd "")))))

(defun claude-follow--read-file (path)
  "The edits in the log PATH; lines that do not parse are skipped."
  (let (rows)
    (with-temp-buffer
      (insert-file-contents path)
      (dolist (line (split-string (buffer-string) "\n" t))
        (when-let* ((row (condition-case nil (json-parse-string line :object-type 'plist)
                           (json-parse-error nil)))
                    (entry (claude-follow--entry row)))
          (push entry rows))))
    rows))

(defun claude-follow--keys (entry)
  "The keys under which ENTRY can be hidden: its session, workspace and project."
  (let ((session (plist-get entry :session)))
    (list (list 'session session)
          (list 'workspace session (plist-get entry :workspace))
          (list 'project (plist-get entry :project)))))

(defun claude-follow--hidden-p (entry)
  "Non-nil when ENTRY is at or before the time one of its keys was hidden."
  (seq-some (lambda (key)
              (when-let* ((at (alist-get key claude-follow--hidden nil nil #'equal)))
                (<= (plist-get entry :ts) at)))
            (claude-follow--keys entry)))

(defun claude-follow--project-gone-p (entry)
  "Non-nil when ENTRY's project is no longer on disk.
A project is a directory (a removed worktree, say), or the file itself for one
like ~/.bashrc.  A remote path is never checked."
  (let ((project (plist-get entry :project)))
    (not (or (file-remote-p project)
             (file-directory-p project)
             (and (equal project (expand-file-name (plist-get entry :file)))
                  (file-exists-p project))))))

(defun claude-follow--archived-p (entry newest &optional gone)
  "Non-nil when ENTRY belongs in the Archive.
That is when its session ended (`:ended'), it was hidden, its project is gone
from disk, or NEWEST, the time of the latest edit of its project, is older than
`claude-follow-archive-after'.  GONE caches `claude-follow--project-gone-p' by
project path across one read."
  (or (plist-get entry :ended)
      (claude-follow--hidden-p entry)
      (> (- (float-time) newest) claude-follow-archive-after)
      (let ((project (plist-get entry :project)))
        (if (and gone (not (eq (gethash project gone 'unknown) 'unknown)))
            (gethash project gone)
          (let ((missing (claude-follow--project-gone-p entry)))
            (when gone (puthash project missing gone))
            missing)))))

(defun claude-follow--rows ()
  "All rows of all logs, edits and `done' markers alike.
Rows of the logs in archive/ (finished sessions) carry `:ended'.
A log that goes away while being read is skipped."
  (let ((archive (expand-file-name "archive" claude-follow-dir)) rows)
    (dolist (ended '(nil t))
      (dolist (path (let ((dir (if ended archive claude-follow-dir)))
                      (and (file-directory-p dir) (directory-files dir t "\\.jsonl\\'"))))
        (dolist (row (condition-case nil (claude-follow--read-file path) (file-error nil)))
          (push (if ended (plist-put row :ended t) row) rows))))
    rows))

(defun claude-follow--done-p (row)
  "Non-nil when ROW is a subagent's `done' marker, not an edit."
  (equal (plist-get row :tool) "done"))

(defun claude-follow--newest-first (entries limit)
  "The first LIMIT of ENTRIES, newest first."
  (seq-take (sort entries (lambda (a b) (> (plist-get a :ts) (plist-get b :ts)))) limit))

(defun claude-follow--split (rows)
  "The edits among ROWS as (LIVE . ARCHIVED), each newest first and capped."
  (let ((edits (seq-remove #'claude-follow--done-p rows))
        (newest (make-hash-table :test 'equal))
        (gone (make-hash-table :test 'equal))
        live archived)
    (dolist (e edits)
      (let ((key (cons (plist-get e :session) (plist-get e :project))))
        (puthash key (max (plist-get e :ts) (gethash key newest 0)) newest)))
    (dolist (e edits)
      (if (claude-follow--archived-p
           e (gethash (cons (plist-get e :session) (plist-get e :project)) newest) gone)
          (push e archived)
        (push e live)))
    (cons (claude-follow--newest-first live claude-follow-max-entries)
          (claude-follow--newest-first archived claude-follow-archive-max-entries))))

(defun claude-follow--read ()
  "The live edits from the log directory, newest first, at most the cap."
  (car (claude-follow--split (claude-follow--rows))))

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

(defun claude-follow--relative (file project)
  "FILE relative to PROJECT when it is under it (its own name when it is the project)."
  (cond ((equal file project) (file-name-nondirectory file))
        ((string-prefix-p (file-name-as-directory project) file)
         (file-relative-name file project))
        (t (abbreviate-file-name file))))

;; A file section's value is (FILE WORKTREE COMMIT); COMMIT is nil for an edit,
;; and "" for an older git row that has no commit id.
(defun claude-follow--commit (entry)
  "The commit of ENTRY when it comes from git, else nil."
  (and (equal (plist-get entry :tool) "commit") (plist-get entry :commit)))

(defface claude-follow-outside '((t :inherit font-lock-keyword-face :weight bold))
  "Workspace and project headings of files outside the treebundel layout (~/claude)."
  :group 'tools)

(defface claude-follow-flash '((t :inherit region :extend t))
  "The flash on a heading or a changed region: the theme's selection colour."
  :group 'tools)

(defconst claude-follow-pulse-delay 0.06
  "Seconds between the steps of a flash.")

(defconst claude-follow-pulse-iterations 20
  "Steps of a flash: with `claude-follow-pulse-delay' about 1.2 s of fade.")

(defface claude-follow-recent
  '((((background dark)) :background "#2e4258" :extend t)
    (t :background "#d3deea" :extend t))
  "The dim mark that stays after a flash on what auto-follow last showed."
  :group 'tools)

(defvar claude-follow-recent-linger 600
  "Seconds a `claude-follow-recent' mark stays.")

(defvar claude-follow--recent nil
  "The one lingering overlay on a shown change, or nil.")

(defvar claude-follow--recent-timer nil
  "The timer that clears `claude-follow--recent'.")

(defvar claude-follow--recent-marks nil
  "The marked edit lines of the follow buffer: ((SESSION PROJECT) TS . UNTIL).")

(defun claude-follow--mark-recent (beg end)
  "Mark BEG to END of the current buffer as the change shown last.
One overlay only, replacing the previous one anywhere, cleared after
`claude-follow-recent-linger' seconds; the text is not touched."
  (claude-follow--clear-recent)
  (let ((overlay (make-overlay beg end)))
    (overlay-put overlay 'face 'claude-follow-recent)
    (overlay-put overlay 'evaporate t)
    (setq claude-follow--recent overlay
          claude-follow--recent-timer
          (run-with-timer claude-follow-recent-linger nil #'claude-follow--clear-recent))))

(defun claude-follow--clear-recent ()
  "Remove the lingering overlay and its timer."
  (when claude-follow--recent-timer
    (cancel-timer claude-follow--recent-timer)
    (setq claude-follow--recent-timer nil))
  (when claude-follow--recent
    (delete-overlay claude-follow--recent)
    (setq claude-follow--recent nil)))

(defun claude-follow--kind (file)
  "Non-nil (`home', `tmp' or `other') when FILE is outside ~/claude."
  (let ((path (expand-file-name file)))
    (cond ((string-prefix-p (file-name-as-directory (expand-file-name "~/claude")) path) nil)
          ((claude-follow--home-part path) 'home)
          ((claude-follow--tmp-parts path) 'tmp)
          (t 'other))))

(defun claude-follow--face (treebundel-face fallback &optional kind)
  "`claude-follow-outside' for an outside KIND, else TREEBUNDEL-FACE when treebundel
defines it, else FALLBACK."
  (cond (kind 'claude-follow-outside)
        ((facep treebundel-face) treebundel-face)
        (t fallback)))

(defun claude-follow--agent-tag (entry)
  "A dim tag naming the subagent that made ENTRY, empty for the session's own edits."
  (let ((agent (plist-get entry :agent)) (type (plist-get entry :agent_type)))
    (if (claude-follow--main-p agent)
        ""
      (propertize (format "  %s %.7s" (if (string-empty-p type) "agent" type) agent)
                  'font-lock-face 'shadow))))

;; A project starts collapsed; Magit's visibility cache keeps one the user opened.
;; The agent buffer, which shows one agent's edits, binds this to keep them open.
(defvar claude-follow--expand-projects nil)

(defun claude-follow--dim (archived face)
  "`shadow' for ARCHIVED drawing, else FACE."
  (if archived 'shadow face))

(defvar claude-follow-project-limit 10
  "How many edits a project lists before \"N more edits\"; `+' doubles it for one project.")

(defvar claude-follow--shown nil
  "Alist of (PROJECT . COUNT): the edits shown for a project that `+' widened.")

(defun claude-follow--shown (project)
  "How many edits of PROJECT to list."
  (or (alist-get project claude-follow--shown nil nil #'equal) claude-follow-project-limit))

(defun claude-follow--project-name (project)
  "The plain directory name of PROJECT, or the whole path for a top directory."
  (let ((name (file-name-nondirectory (directory-file-name project))))
    (if (string-empty-p name) project name)))

(defun claude-follow--recent-p (entry)
  "Non-nil when ENTRY is the newest edit of a project that changed recently."
  (when-let* ((mark (assoc (list (plist-get entry :session) (plist-get entry :project))
                           claude-follow--recent-marks)))
    (and (= (cadr mark) (plist-get entry :ts))
         (< (float-time) (cddr mark)))))

(defun claude-follow--insert-edit (entry project worktree archived)
  "Insert the line of the edit ENTRY of PROJECT; ARCHIVED draws it dimmed."
  (claude-follow--insert-edit-line entry project worktree archived))

(defvar claude-follow--subjects (make-hash-table :test #'equal)
  "Commit subjects already read, by commit id.")

(defun claude-follow--commit-subject (entry worktree)
  "The subject line of the commit of ENTRY in WORKTREE, or nil."
  (when-let* ((commit (claude-follow--commit entry))
              ((not (string-empty-p commit)))
              ((stringp worktree))
              ((file-directory-p worktree)))
    (or (gethash commit claude-follow--subjects)
        (let* ((default-directory worktree)
               (subject (with-temp-buffer
                          (and (eq 0 (call-process "git" nil t nil "log" "-1" "--format=%s" commit))
                               (string-trim (buffer-string))))))
          (and subject (not (string-empty-p subject))
               (puthash commit subject claude-follow--subjects))))))

(defun claude-follow--insert-edit-line (entry project worktree archived)
  "Insert the section and line of the edit ENTRY of PROJECT; ARCHIVED dims it."
  (magit-insert-section (claude-follow-file (list (plist-get entry :file) worktree
                                                  (claude-follow--commit entry) (plist-get entry :ts)))
    (insert "      "
            (propertize (claude-follow--time (plist-get entry :ts)) 'font-lock-face 'shadow)
            "  "
            (propertize (or (claude-follow--commit-subject entry worktree)
                            (claude-follow--relative (plist-get entry :file) project))
                        'font-lock-face (claude-follow--dim archived nil))
            (claude-follow--agent-tag entry)
            ;; right-aligned like magit-log's dates, following the window width
            (if-let* ((commit (claude-follow--commit entry)))
                (concat (propertize " " 'display '(space :align-to (- right 8)))
                        (propertize (substring commit 0 (min 7 (length commit)))
                                    'font-lock-face (claude-follow--dim archived 'magit-hash)))
              "")
            "\n")))

(defun claude-follow--insert-project (project entries &optional archived all)
  "Insert PROJECT (a worktree, or a path under $HOME) with one line per edit of ENTRIES.
ENTRIES are newest first; only the first `claude-follow--shown' are listed unless ALL.
ARCHIVED draws it dimmed."
  (let* ((worktree (plist-get (car entries) :worktree))
         (listed (if all entries (seq-take entries (claude-follow--shown project))))
         (more (- (length entries) (length listed))))
    (magit-insert-section (claude-follow-worktree (cons project worktree) (not claude-follow--expand-projects))
      (magit-insert-heading
        "    "
        (propertize (claude-follow--project-name project)
                    'font-lock-face (claude-follow--dim
                                     archived (claude-follow--face 'treebundel-project 'magit-branch-local
                                                                   (plist-get (car entries) :kind)))
                    'help-echo (abbreviate-file-name project))
        (format " (%d)" (length entries)))
      (dolist (entry listed)
        (claude-follow--insert-edit entry project worktree archived))
      (when (> more 0)
        (magit-insert-section (claude-follow-more (cons project more))
          (insert "      "
                  (propertize (format "%d more edits (SPC m + to show more, RET to open all)\n" more)
                              'font-lock-face 'shadow)))))))

;; No section body ends with a blank line: the blank line between two sessions
;; is inserted outside both, so folding one never changes the spacing.
(defun claude-follow--insert-separated (items insert)
  "Call INSERT on each of ITEMS with one blank line between consecutive ones."
  (let ((first t))
    (dolist (item items)
      (unless first (insert "\n"))
      (setq first nil)
      (funcall insert item))))

(defun claude-follow--insert-workspace (workspace entries &optional archived)
  "Insert the section of WORKSPACE, one project of ENTRIES; ARCHIVED draws it dimmed."
  (magit-insert-section (claude-follow-workspace workspace)
    (magit-insert-heading
      "  " (propertize workspace
                    'font-lock-face
                    (claude-follow--dim
                     archived (claude-follow--face 'treebundel-workspace 'magit-section-secondary-heading
                                                   (plist-get (car entries) :kind)))))
    (dolist (tree (claude-follow--by-recency (claude-follow--group entries :project)))
      (claude-follow--insert-project (car tree) (cdr tree) archived))))

(defvar claude-follow-manager-session-file "~/.claude/manager-session"
  "File holding the session id of the pinned Manager session.")

(defvar claude-follow-manager-name "Tally"
  "What the pinned Manager session and its own edits are called.")

(defun claude-follow--manager-session ()
  "The id of the pinned Manager session, or nil without one."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents (expand-file-name claude-follow-manager-session-file))
        (string-trim (buffer-string)))
    (file-error nil)))

(defun claude-follow--manager-p (session)
  "Non-nil when SESSION is the pinned Manager session."
  (equal (claude-follow--manager-session) session))

(defun claude-follow--main-p (agent)
  "Non-nil when AGENT names a session's own, not a subagent's, edits."
  (member agent '("claude" "main")))

(defun claude-follow--by-recency (groups)
  "GROUPS (see `claude-follow--group', entries newest first) by their newest edit
first, ties broken by name."
  (sort (copy-sequence groups)
        (lambda (a b)
          (let ((ta (plist-get (cadr a) :ts)) (tb (plist-get (cadr b) :ts)))
            (or (> ta tb) (and (= ta tb) (string< (car a) (car b))))))))

(defun claude-follow--insert-session (session entries &optional archived)
  "Insert the section of SESSION, one subsection per workspace; ARCHIVED draws it dimmed."
  (magit-insert-section (claude-follow-session session)
    (magit-insert-heading
      (if (claude-follow--manager-p session)
          (propertize claude-follow-manager-name 'font-lock-face (claude-follow--dim archived 'magit-section-heading))
        (concat (propertize "Session " 'font-lock-face (claude-follow--dim archived 'magit-section-heading))
                (substring session 0 (min 8 (length session)))))
      (propertize (format "  last %s" (claude-follow--time (plist-get (car entries) :ts)))
                  'font-lock-face 'shadow))
    ;; task workspaces, then `_' ones, then outside ones; `sort' is stable
    ;; newest workspace first, no tiers; they follow each other without a blank line
    (dolist (workspace (claude-follow--by-recency (claude-follow--group entries :workspace)))
      (claude-follow--insert-workspace (car workspace) (cdr workspace) archived))))

(defvar-local claude-follow--log-project nil
  "In a project's log buffer, the project it shows; nil in `*claude-follow*'.")

(defun claude-follow--redraw ()
  "Redraw the follow buffers, when there are any, from the current entries."
  (dolist (buffer (buffer-list))
    (when (eq (buffer-local-value 'major-mode buffer) 'claude-follow-mode)
      (with-current-buffer buffer (claude-follow--draw)))))

(defun claude-follow-refresh ()
  "Read the logs again and redraw, keeping point and folds."
  (interactive)
  (let* ((rows (claude-follow--rows)) (split (claude-follow--split rows)))
    (setq claude-follow--entries (car split)
          claude-follow--archive (cdr split)
          claude-follow--dones (seq-filter #'claude-follow--done-p rows)))
  (claude-follow--redraw))

(defun claude-follow--project-entries (project)
  "All edits of PROJECT, live and archived, newest first."
  (let ((entries (seq-filter (lambda (e) (equal (plist-get e :project) project))
                             (append claude-follow--entries claude-follow--archive))))
    (claude-follow--newest-first entries (length entries))))

(defun claude-follow--draw ()
  "Redraw the current buffer from `claude-follow--entries'."
  (let* ((section (magit-current-section))
         (position (and section (magit-section-get-relative-position section)))
         (inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (claude-follow)
      (if claude-follow--log-project
          (let ((claude-follow--expand-projects t)
                (entries (claude-follow--project-entries claude-follow--log-project)))
            (if entries
                (claude-follow--insert-project claude-follow--log-project entries nil t)
              (insert (propertize "No edits recorded.\n" 'font-lock-face 'shadow))))
      (insert (propertize (format "Auto-follow: %s\n\n" (if claude-follow-auto "on" "off"))
                          'font-lock-face 'shadow))
      (if (and (null claude-follow--entries) (null claude-follow--archive))
          (insert (propertize "No edits recorded.\n" 'font-lock-face 'shadow))
        (claude-follow--insert-separated
         (claude-follow--group claude-follow--entries :session)
         (lambda (session) (claude-follow--insert-session (car session) (cdr session))))
        (when claude-follow--archive
          (when claude-follow--entries (insert "\n"))
          (magit-insert-section (claude-follow-archive nil t)
            (magit-insert-heading
              (propertize (format "Archive (%d)" (length claude-follow--archive))
                          'font-lock-face 'shadow))
            (claude-follow--insert-separated
             (claude-follow--group claude-follow--archive :session)
             (lambda (session) (claude-follow--insert-session (car session) (cdr session) t))))))))
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

(defun claude-follow--section-type ()
  "The type of the section at point, or nil."
  (when-let* ((section (magit-current-section))) (oref section type)))

(defun claude-follow--worktree-at-point ()
  "The worktree of the file or worktree section at point, or nil."
  (when-let* ((section (magit-current-section)))
    (pcase (oref section type)
      ('claude-follow-file (cadr (oref section value)))
      ('claude-follow-worktree (cdr (oref section value))))))

(defun claude-follow--key-at-point ()
  "The key of the session, workspace or project section at point (a file hides its worktree)."
  (when-let* ((section (magit-current-section)))
    (pcase (oref section type)
      ('claude-follow-session (list 'session (oref section value)))
      ('claude-follow-workspace (list 'workspace (oref (oref section parent) value) (oref section value)))
      ('claude-follow-worktree (list 'project (car (oref section value))))
      ((or 'claude-follow-file 'claude-follow-more) (list 'project (car (oref (oref section parent) value)))))))

(defun claude-follow--hide (keys &optional now)
  "Archive KEYS as of NOW (default the current time), redraw, and return how many edits moved."
  (let ((before (length claude-follow--entries)))
    (dolist (key keys)
      (push (cons key (or now (float-time))) claude-follow--hidden))
    (claude-follow-refresh)
    (- before (length claude-follow--entries))))

(defun claude-follow-hide ()
  "Move the session, workspace or project section at point to the Archive (until newer edits arrive)."
  (interactive)
  (if-let* ((key (claude-follow--key-at-point)))
      (message "claude-follow: archived %s %s (%d entries)" (car key) (car (last key))
               (claude-follow--hide (list key)))
    (user-error "No session, workspace or project here")))

(defun claude-follow-hide-all ()
  "Move everything currently listed to the Archive."
  (interactive)
  (let ((keys (delete-dups (mapcar (lambda (e) (list 'session (plist-get e :session)))
                                   claude-follow--entries))))
    (message "claude-follow: archived all (%d entries)" (claude-follow--hide keys))))

(defun claude-follow-show-all ()
  "Bring back everything that was archived by hand."
  (interactive)
  (setq claude-follow--hidden nil)
  (let ((before (length claude-follow--entries)))
    (claude-follow-refresh)
    (message "claude-follow: showing all (%d more entries)" (- (length claude-follow--entries) before))))

(defun claude-follow--show-commit ()
  "Magit's diff of the commit at point for its file, else the file's log."
  (let ((commit (claude-follow--commit-at-point))
        (file (claude-follow--file-at-point)))
    (claude-follow--in-worktree
     (lambda ()
       (let ((relative (file-relative-name file default-directory)))
         (if (string-empty-p commit)
             (magit-log-current nil (list relative))
           (claude-follow--visit-magit #'magit-show-commit commit nil (list relative))))))))

(defun claude-follow--find-commit-section (commit)
  "The `commit' section of COMMIT under the status buffer's commit lists, or nil."
  (seq-some
   (lambda (section)
     (seq-find (lambda (child)
                 (and (eq (oref child type) 'commit)
                      (let ((id (oref child value)))
                        (and (stringp id)
                             (or (string-prefix-p commit id) (string-prefix-p id commit))))))
               (oref section children)))
   (seq-filter (lambda (section) (memq (oref section type) '(unpushed unpulled recent)))
               (oref magit-root-section children))))

(defun claude-follow--status-commit (commit)
  "Magit status of the worktree at point with point on COMMIT, else show it.
COMMIT is found among the unpushed, unpulled and recent commit sections;
an older one falls back to `magit-show-commit' for its full id."
  (let ((file (claude-follow--file-at-point)))
    (claude-follow--in-worktree
     (lambda ()
       (claude-follow--visit-magit #'magit-status-setup-buffer default-directory)
       (let* ((buffer (magit-get-mode-buffer 'magit-status-mode))
              (found (and buffer
                          (with-current-buffer buffer
                            (claude-follow--find-commit-section commit)))))
         (if found
             (with-current-buffer buffer
               (goto-char (oref found start))
               (magit-section-show found)
               (when-let* ((window (get-buffer-window buffer t)))
                 (set-window-point window (point))))
           (message "claude-follow: %s is older than the recent commits; showing its diff"
                    (substring commit 0 (min 8 (length commit))))
           (claude-follow--visit-magit #'magit-show-commit commit nil
                              (list (file-relative-name file default-directory)))))))))

(defun claude-follow--project-at-point ()
  "The project of the project section, edit or \"more edits\" line at point, or nil."
  (when-let* ((section (magit-current-section)))
    (pcase (oref section type)
      ((or 'claude-follow-worktree 'claude-follow-more) (car (oref section value)))
      ('claude-follow-file (car (oref (oref section parent) value))))))

(defvar claude-follow--visit-window nil
  "The window the last RET visit used.")

(defun claude-follow--visit-buffer (buffer)
  "Show BUFFER and select its window, always reusing the same one.
That is the window of the previous visit while it lives, else another
window of the frame that is not the follow window, else a new split.
Returns BUFFER's window; usable as `magit-display-buffer-function'."
  (let* ((here (selected-window))
         (window (cond ((and (window-live-p claude-follow--visit-window)
                             (not (eq claude-follow--visit-window here)))
                        claude-follow--visit-window)
                       ((seq-find (lambda (w) (not (eq w here))) (window-list nil 'never here)))
                       (t (split-window-sensibly here)))))
    (unless window (setq window (split-window here nil 'right)))
    (set-window-buffer window buffer)
    (setq claude-follow--visit-window window)
    (select-window window)
    window))

(defun claude-follow--visit-magit (fn &rest args)
  "Call the Magit command FN with ARGS, displaying its buffer by `claude-follow--visit-buffer'."
  (let ((magit-display-buffer-function #'claude-follow--visit-buffer))
    (apply fn args)))

(defun claude-follow--stop-auto ()
  "Turn auto-follow off, saying so, before the user reads something; no-op when off."
  (when claude-follow-auto (claude-follow-toggle-auto)))

(defun claude-follow-project-log ()
  "Open `*claude-follow: PROJECT*', all the edits of the project at point."
  (interactive)
  (let* ((project (or (claude-follow--project-at-point) (user-error "No project at point")))
         (_ (claude-follow--stop-auto))
         (buffer (get-buffer-create
                  (format "*claude-follow: %s*" (abbreviate-file-name project)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'claude-follow-mode) (claude-follow-mode))
      (setq claude-follow--log-project project)
      (claude-follow--draw))
    (claude-follow--visit-buffer buffer)))

(defun claude-follow-more-edits ()
  "List twice as many edits for the project at point."
  (interactive)
  (let ((project (or (claude-follow--project-at-point) (user-error "No project at point"))))
    (setf (alist-get project claude-follow--shown nil nil #'equal)
          (* 2 (claude-follow--shown project)))
    (claude-follow--redraw)))

(defun claude-follow-visit ()
  "Visit the file at point, or show its commit in Magit; else toggle the section.
On a \"more edits\" line, open the project's whole log."
  (interactive)
  (if-let* ((file (claude-follow--file-at-point)))
      (let ((commit (claude-follow--commit-at-point)))
        (claude-follow--stop-auto)
        (cond ((null commit) (claude-follow--visit-buffer (find-file-noselect file)))
              ((string-empty-p commit) (claude-follow--show-commit))
              (t (claude-follow--status-commit commit))))
    (when-let* ((section (magit-current-section)))
      (if (eq (oref section type) 'claude-follow-more)
          (claude-follow-project-log)
        (magit-section-toggle section)))))

(defun claude-follow--in-archive-p ()
  "Non-nil when point is in the Archive section."
  (let ((section (magit-current-section)))
    (while (and section (not (eq (oref section type) 'claude-follow-archive)))
      (setq section (oref section parent)))
    (and section t)))

(defun claude-follow--reveal ()
  "Open the collapsed sections around the edit at point."
  (when-let* ((section (magit-current-section))
              ((eq (oref section type) 'claude-follow-file)))
    (while (setq section (oref section parent))
      (magit-section-show section))))

(defun claude-follow--edit-line-p (archive)
  "Non-nil on an edit line in the live part (ARCHIVE nil) or in the Archive (t)."
  (and (claude-follow--file-at-point) (eq archive (claude-follow--in-archive-p))))

(defun claude-follow-next-edit ()
  "Move to the next edited file, opening its project; the Archive only from inside it."
  (interactive)
  (let ((archive (claude-follow--in-archive-p)))
    (forward-line 1)
    (while (and (not (eobp)) (not (claude-follow--edit-line-p archive))) (forward-line 1))
    (claude-follow--reveal)))

(defun claude-follow-previous-edit ()
  "Move to the previous edited file."
  (interactive)
  (let ((start (point)) (archive (claude-follow--in-archive-p)))
    (forward-line -1)
    (while (and (not (bobp)) (not (claude-follow--edit-line-p archive))) (forward-line -1))
    (if (claude-follow--edit-line-p archive) (claude-follow--reveal) (goto-char start))))

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

(defvar claude-follow--timer)

(defun claude-follow-toggle-auto ()
  "Turn auto-follow on or off."
  (interactive)
  (setq claude-follow-auto (not claude-follow-auto))
  (unless claude-follow-auto
    (claude-follow--clear-recent)
    (when (timerp claude-follow--timer) (cancel-timer claude-follow--timer)))
  (claude-follow--redraw)
  (message "claude-follow: auto-follow %s" (if claude-follow-auto "on" "off")))

;; Every revert, auto-revert-mode's included (it often gets there first), records
;; what it changed while auto-follow is on, so the show can flash all of it.
(defvar-local claude-follow--before nil
  "The buffer text just before a revert.")

(defvar-local claude-follow--region nil
  "What the last revert changed, (BEG END TIME), or nil.")

(defun claude-follow--before-revert ()
  "Keep the text a revert is about to replace; a revert drops the lingering mark."
  (when (and claude-follow--recent (eq (overlay-buffer claude-follow--recent) (current-buffer)))
    (claude-follow--clear-recent))
  (setq claude-follow--before (and claude-follow-auto (buffer-string))))

(defun claude-follow--after-revert ()
  "Record, and flash when visible, the region the revert changed."
  (when-let* ((old claude-follow--before))
    (setq claude-follow--before nil)
    (let* ((new (buffer-string))
           (head (let ((c (compare-strings old nil nil new nil nil)))
                   (if (eq c t) (length new) (1- (abs c)))))
           (tail (let ((n 0) (lo (length old)) (ln (length new)))
                   (while (and (< n (- (min lo ln) head))
                               (eq (aref old (- lo n 1)) (aref new (- ln n 1))))
                     (setq n (1+ n)))
                   n)))
      (when (< head (- (length new) tail))
        (setq claude-follow--region (list (1+ head) (1+ (- (length new) tail)) (float-time)))
        (when (get-buffer-window (current-buffer) t)
          (claude-follow--pulse claude-follow--region))))))

(add-hook 'before-revert-hook #'claude-follow--before-revert)
(add-hook 'after-revert-hook #'claude-follow--after-revert)

(defun claude-follow--recent-region ()
  "The region the last revert changed, if that was in the last 10 seconds."
  (and claude-follow--region
       (< (- (float-time) (nth 2 claude-follow--region)) 10)
       claude-follow--region))

(defun claude-follow--revert ()
  "Revert the current buffer when its file changed on disk, keeping point.
The hooks record and flash the change. A buffer that is current already,
auto-revert having got there first, is left alone."
  (unless (verify-visited-file-modtime)
    (let ((point (point)))
      (revert-buffer t t t)
      (goto-char (min point (point-max))))))

(defun claude-follow--pulse (region)
  "Flash REGION, a list (BEG END ...), with `claude-follow-flash'."
  (let ((pulse-delay claude-follow-pulse-delay)
        (pulse-iterations claude-follow-pulse-iterations))
    (pulse-momentary-highlight-region (car region) (cadr region) 'claude-follow-flash)))

(defvar-local claude-follow--mode-line-flash nil
  "A running mode-line flash: (TIMER . FACE-REMAP-COOKIES).")

(defun claude-follow--unflash-mode-line (buffer)
  "End the mode-line flash of BUFFER, if one runs."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when claude-follow--mode-line-flash
        (cancel-timer (car claude-follow--mode-line-flash))
        (mapc #'face-remap-remove-relative (cdr claude-follow--mode-line-flash))
        (setq claude-follow--mode-line-flash nil)
        (force-mode-line-update)))))

(defun claude-follow--flash-mode-line (window)
  "Flash the mode line of WINDOW: its buffer's `mode-line' faces are remapped to
`claude-follow-flash' for the length of a pulse, then put back."
  (with-current-buffer (window-buffer window)
    (claude-follow--unflash-mode-line (current-buffer))
    (let ((cookies (mapcar (lambda (face) (face-remap-add-relative face 'claude-follow-flash))
                           '(mode-line-active mode-line))))
      (setq claude-follow--mode-line-flash
            (cons (run-with-timer (* claude-follow-pulse-delay claude-follow-pulse-iterations) nil
                                  #'claude-follow--unflash-mode-line (current-buffer))
                  cookies)))
    (force-mode-line-update)))

(defun claude-follow--archived-section-p (section)
  "Non-nil when SECTION is inside the Archive."
  (while (and section (not (eq (oref section type) 'claude-follow-archive)))
    (setq section (oref section parent)))
  (and section t))

(defun claude-follow--visible-heading (section)
  "The section whose heading shows SECTION's place: the outermost collapsed ancestor, else SECTION."
  (let ((shown section))
    (let ((ancestor (oref section parent)))
      (while ancestor
        (when (oref ancestor hidden) (setq shown ancestor))
        (setq ancestor (oref ancestor parent))))
    shown))

(defun claude-follow--pulse-projects (fresh)
  "Flash, once each, the new edit lines of the fresh edits FRESH.
When their project is collapsed, the heading that stands for it flashes instead:
the project's, or the outermost collapsed workspace or session above it.  Only when the follow buffer is shown in a window; point and windows
stay put.  A heading outside the window's visible part is not scrolled to:
the window's mode line flashes instead and the echo area says which project
changed and whether it is above or below."
  (when-let* ((buffer (get-buffer "*claude-follow*"))
              (window (get-buffer-window buffer t)))
    (let ((targets (delete-dups (mapcar (lambda (e) (cons (plist-get e :session) (plist-get e :project)))
                                        fresh)))
          (top (window-start window))
          (bottom (window-end window t))
          headings above below)
      (with-current-buffer buffer
        (magit-map-sections
         (lambda (section)
           (when (and (eq (oref section type) 'claude-follow-worktree)
                      (not (claude-follow--archived-section-p section))
                      (member (cons (oref (oref (oref section parent) parent) value)
                                    (car (oref section value)))
                              targets))
             (let ((heading (claude-follow--visible-heading section))
                   (project (car (oref section value))))
               ;; the new lines themselves when they are shown, else the
               ;; heading that stands for them
               (if (eq heading section)
                   (let ((count (seq-count (lambda (e) (equal (plist-get e :project) project)) fresh)))
                     (dolist (line (seq-take (oref section children) count))
                       (unless (assq line headings)
                         (push (cons line project) headings))))
                 (unless (assq heading headings)
                   (push (cons heading project) headings)))))))
        (pcase-dolist (`(,heading . ,project) headings)
          (let ((start (oref heading start)))
            (cond ((< start top) (push project above))
                  ((>= start bottom) (push project below))
                  (t (save-excursion
                       (goto-char start)
                       (claude-follow--pulse (list (point) (line-beginning-position 2))))))))
        (when (or above below)
          (claude-follow--flash-mode-line window)
          (message "claude-follow: %s"
                   (mapconcat #'identity
                              (delq nil (list (and above (format "%s changed (above)" (string-join above ", ")))
                                              (and below (format "%s changed (below)" (string-join below ", ")))))
                              "; ")))))))

(defun claude-follow--pulse-appeared (old new)
  "Flash the headings of workspaces and projects in NEW that OLD did not have.
Only the ones inside the follow window's visible part."
  (when-let* ((buffer (get-buffer "*claude-follow*"))
              (window (get-buffer-window buffer t)))
    (cl-flet ((keys (entries)
                (mapcan (lambda (e)
                          (let ((s (plist-get e :session)))
                            (list (list s (plist-get e :workspace))
                                  (list s (plist-get e :workspace) (plist-get e :project)))))
                        entries)))
      (let ((known (keys old))
            (top (window-start window))
            (bottom (window-end window t)))
        (with-current-buffer buffer
          (magit-map-sections
           (lambda (section)
             (let ((key (pcase (oref section type)
                          ('claude-follow-workspace
                           (list (oref (oref section parent) value) (oref section value)))
                          ('claude-follow-worktree
                           (list (oref (oref (oref section parent) parent) value)
                                 (oref (oref section parent) value)
                                 (car (oref section value)))))))
               (when (and key (not (member key known))
                          (not (claude-follow--archived-section-p section))
                          (<= top (oref section start))
                          (< (oref section start) bottom))
                 (save-excursion
                   (goto-char (oref section start))
                   (claude-follow--pulse (list (point) (line-beginning-position 2)))))))))))))

(defun claude-follow--refresh-worktree (worktree)
  "Refresh the Magit buffers of WORKTREE, quietly."
  (let ((inhibit-message t))
    (ignore-errors
      (dolist (buffer (magit-mode-get-buffers))
        (with-current-buffer buffer
          (when (equal (magit-toplevel) (file-name-as-directory worktree))
            (magit-refresh-buffer)))))))

(defun claude-follow--refresh-file (file)
  "Revert the unmodified buffer visiting FILE, if any, and its diff-hl, quietly."
  (when-let* ((buffer (find-buffer-visiting file)))
    (with-current-buffer buffer
      (let ((inhibit-message t))
        (ignore-errors
          (unless (buffer-modified-p) (claude-follow--revert))
          (when (bound-and-true-p diff-hl-mode) (diff-hl-update)))))))

(defun claude-follow--apply (entries)
  "Bring Emacs up to date with the fresh ENTRIES: each worktree and file once."
  (dolist (worktree (seq-uniq (mapcar (lambda (e) (plist-get e :worktree)) entries)))
    (unless (string-empty-p worktree) (claude-follow--refresh-worktree worktree)))
  (mapc #'claude-follow--refresh-file (seq-uniq (mapcar (lambda (e) (plist-get e :file)) entries))))

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
    (if (and (eql 0 (condition-case nil
                        (call-process "git" nil t nil "-C" worktree "diff" "-U0" "--no-color" "--no-ext-diff" "--no-textconv"
                                      "--" file)
                      (file-error nil)))
             (> (buffer-size) 0))
        (claude-follow--hunk-line (buffer-string))
      1)))

(defun claude-follow--show-file (file worktree)
  "Show FILE reverted from disk in the follow window and flash the change.
The change is what the revert altered (here, or already in auto-follow's
`claude-follow--refresh-file'); a buffer that was not visiting FILE yet falls back to
the first line of git's first hunk."
  ;; `find-file-noselect' on a buffer stale on disk asks to reread, so only for a
  ;; new one; the file is an agent's, so its unsafe local variables neither run
  ;; nor ask (this runs from a timer, an ask would be a surprise).
  (let* ((visiting (find-buffer-visiting file))
         (fresh (not visiting))
         (buffer (or visiting (let ((enable-local-variables :safe)) (find-file-noselect file)))))
    (when-let* ((window (claude-follow--display buffer)))
      (with-current-buffer buffer
        (unless (or fresh (buffer-modified-p)) (claude-follow--revert))
        (let ((region (unless fresh (claude-follow--recent-region))))
          (unless region
            (save-excursion
              (goto-char (point-min))
              (forward-line (1- (claude-follow--file-line file worktree)))
              (setq region (list (point) (line-beginning-position 2)))))
          (set-window-point window (car region))
          (claude-follow--scroll-to window (car region) (cadr region))
          (claude-follow--pulse region)
          (claude-follow--mark-recent (car region) (cadr region)))))))

(defun claude-follow--scroll-to (window beg &optional end)
  "Center the change at BEG (through END) vertically in WINDOW.
The line centered is the middle of the region when it fits the window, else
its first line.  Nothing moves when that line already sits in the middle half
of the window; WINDOW is not selected.  BEG and END are positions in the
current buffer, so nothing happens unless WINDOW shows it."
  (when (eq (window-buffer window) (current-buffer))
    (let* ((height (window-body-height window))
           (lines (if end (count-lines beg end) 1))
           (focus (save-excursion
                    (goto-char beg)
                    (forward-line (if (< lines height) (/ lines 2) 0))
                    (line-beginning-position)))
           (top (window-start window))
           (quarter (/ height 4))
           (lo (save-excursion (goto-char top) (forward-line quarter) (point)))
           (hi (save-excursion (goto-char top) (forward-line (- height quarter)) (point))))
      (unless (and (>= focus lo) (< focus hi) (< focus (window-end window t)))
        (set-window-point window focus)
        ;; `recenter' works on the selected window; NORECORD keeps the user's
        ;; focus and buffer order, and the selection comes back afterwards.
        (with-selected-window window (recenter))))))

(defun claude-follow--show-magit-file (mode rel)
  "In the shown Magit buffer of MODE, scroll to REL's first hunk and flash it.
The file's heading is the target when it has no hunk or is collapsed."
  (when-let* ((buffer (magit-get-mode-buffer mode))
              (window (get-buffer-window buffer t)))
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward (concat "^[a-z ]+ +" (regexp-quote rel) "$") nil t)
          (let* ((file (magit-section-at (line-beginning-position)))
                 (hunk (and file (not (oref file hidden))
                            (seq-find (lambda (c) (eq (oref c type) 'hunk)) (oref file children))))
                 (target (if hunk (oref hunk start) (line-beginning-position))))
            (goto-char target)
            (set-window-point window target)
            (claude-follow--scroll-to window target)
            (claude-follow--pulse (list target (line-beginning-position 2)))
            (claude-follow--mark-recent target (line-beginning-position 2))))))))

(defun claude-follow--show-magit (fn &rest args)
  "Call the Magit command FN with ARGS, displaying its buffer without selecting it."
  (let ((magit-display-buffer-noselect t)
        (magit-display-buffer-function #'claude-follow--display))
    (apply fn args)))

(defun claude-follow--show-status (worktree)
  "Show Magit's status of WORKTREE in the follow window, without selecting it."
  (let ((default-directory (file-name-as-directory worktree)))
    (claude-follow--show-magit #'magit-status-setup-buffer default-directory)))

(defun claude-follow-status ()
  "Show Magit's status of the project at point in the follow window."
  (interactive)
  (let ((worktree (and (memq (claude-follow--section-type) '(claude-follow-worktree claude-follow-file))
                       (claude-follow--worktree-at-point))))
    (cond ((null worktree) (message "claude-follow: no project at point"))
          ((string-empty-p worktree) (message "claude-follow: not a repository"))
          (t (claude-follow--show-status worktree)))))

;; A subagent that stops leaves a `done' marker row in the logs (follow-hook.sh on
;; SubagentStop); when a fresh one arrives its projects' status is shown.
(defvar claude-follow-status-on-done t
  "Non-nil: show a project's Magit status when a subagent that edited it is done.")

(defun claude-follow--projects-of (done)
  "The worktrees edited by the agent and session of the marker row DONE."
  (delete-dups
   (seq-filter (lambda (w) (not (string-empty-p w)))
               (mapcar (lambda (e) (plist-get e :worktree))
                       (seq-filter (lambda (e) (and (equal (plist-get e :session) (plist-get done :session))
                                                    (equal (plist-get e :agent) (plist-get done :agent))))
                                   claude-follow--entries)))))

(defun claude-follow--on-done (fresh)
  "Show the status of the projects of the agents whose marker rows FRESH are new."
  (when (and fresh claude-follow-status-on-done claude-follow-display claude-follow-auto)
    (dolist (done fresh)
      (mapc #'claude-follow--show-status (claude-follow--projects-of done)))))

(defun claude-follow-toggle-status-on-done ()
  "Turn showing the status of a finished agent's projects on or off."
  (interactive)
  (setq claude-follow-status-on-done (not claude-follow-status-on-done))
  (message "claude-follow: status on done %s" (if claude-follow-status-on-done "on" "off")))

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
               (claude-follow--show-magit #'magit-show-commit commit nil (list rel))
               (claude-follow--show-magit-file 'magit-revision-mode rel))
              (commit nil)
              ((eq claude-follow-display 'diff)
               (claude-follow--show-magit #'magit-diff-unstaged nil (list rel))
               (claude-follow--show-magit-file 'magit-diff-mode rel))
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
    (define-key map (kbd "s") #'claude-follow-status)
    (define-key map (kbd "S") #'claude-follow-toggle-status-on-done)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "RET") #'claude-follow-visit)
    (define-key map (kbd "n") #'claude-follow-next-edit)
    (define-key map (kbd "p") #'claude-follow-previous-edit)
    (define-key map (kbd "d") #'claude-follow-diff)
    (define-key map (kbd "D") #'claude-follow-difftastic)
    (define-key map (kbd "l") #'claude-follow-log)
    (define-key map (kbd "f") #'claude-follow-toggle-auto)
    (define-key map (kbd "v") #'claude-follow-cycle-display)
    (define-key map (kbd "x") #'claude-follow-hide)
    (define-key map (kbd "X") #'claude-follow-hide-all)
    (define-key map (kbd "u") #'claude-follow-show-all)
    (define-key map (kbd "+") #'claude-follow-more-edits)
    (define-key map (kbd "L") #'claude-follow-project-log)
    map))

(define-derived-mode claude-follow-mode magit-section-mode "Claude-Follow"
  "The files Claude sessions and their subagents edited, by session, workspace and project."
  (setq default-directory (file-name-as-directory (expand-file-name "~/claude"))))

;; Vim's fold keys, for evil. Each goes through `magit-section-show'/`-hide',
;; which record the result in Magit's visibility cache, so it survives a refresh.
(defun claude-follow-collapse (section)
  "Close SECTION and everything under it."
  (interactive (list (magit-current-section)))
  (magit-map-sections #'magit-section-hide section))

(defun claude-follow-expand-all ()
  "Open every section of the buffer, the Archive included."
  (interactive)
  (magit-map-sections #'magit-section-show))

(defun claude-follow-collapse-all ()
  "Close everything below the top-level sections, keeping their headings."
  (interactive)
  (dolist (top (oref magit-root-section children))
    (mapc #'claude-follow-collapse (oref top children))
    (magit-section-show top)))

;; Fold levels, as vim's zm/zr step through them: level N shows every section
;; less than N deep and closes the rest (so level 3 is magit's M-3: sessions and
;; workspaces open, projects closed), the deepest level opens everything. They
;; are read off the sections each time, so manual folds never leave them stale.
(defun claude-follow--depth (section)
  "How many parents SECTION has: 1 for a top-level section."
  (let ((depth 0))
    (while (setq section (oref section parent))
      (setq depth (1+ depth)))
    depth))

(defun claude-follow--fold-levels ()
  "Return (CURRENT . LAST): the level the buffer is folded to and the open one.
A section with nothing under it (an edit line) does not count."
  (let ((deepest 0) (lowest most-positive-fixnum))
    (magit-map-sections
     (lambda (section)
       (unless (or (eq section magit-root-section)
                   (not (or (oref section children) (oref section content))))
         (let ((depth (claude-follow--depth section)))
           (setq deepest (max deepest depth))
           (when (oref section hidden)
             (setq lowest (min lowest depth)))))))
    (cons (min lowest (1+ deepest)) (1+ deepest))))

(defun claude-follow--fold-to (level)
  "Fold the buffer to LEVEL and say so."
  (let ((last (cdr (claude-follow--fold-levels))))
    (setq level (max 1 (min level last)))
    (magit-map-sections
     (lambda (section)
       (unless (eq section magit-root-section)
         (if (< (claude-follow--depth section) level)
             (magit-section-show section)
           (magit-section-hide section)))))
    (message "fold level %d/%d" level last)))

(defun claude-follow-fold-more ()
  "Close one more level of the tree."
  (interactive)
  (claude-follow--fold-to (1- (car (claude-follow--fold-levels)))))

(defun claude-follow-fold-less ()
  "Open one more level of the tree."
  (interactive)
  (claude-follow--fold-to (1+ (car (claude-follow--fold-levels)))))

;; Under evil only navigation and structure stay unprefixed (gg, gr and the fold
;; keys are evil's own); the rest lives under the local leader, SPC m.
(declare-function evil-define-key* "evil-core")
(declare-function which-key-add-major-mode-key-based-replacements "which-key")

(defun claude-follow--bind-folds (map)
  "Bind vim's fold keys on magit sections in MAP for evil."
  (evil-define-key* '(normal motion) map
    (kbd "za") #'magit-section-toggle
    (kbd "zo") #'magit-section-show
    (kbd "zc") #'magit-section-hide
    (kbd "zO") #'magit-section-show-children
    (kbd "zC") #'claude-follow-collapse
    (kbd "zr") #'claude-follow-fold-less
    (kbd "zR") #'claude-follow-expand-all
    (kbd "zm") #'claude-follow-fold-more
    (kbd "zM") #'claude-follow-collapse-all))

(defun claude-follow--bind-leader (mode map bindings)
  "Bind BINDINGS, an alist of (KEY . COMMAND), under SPC m in MAP of MODE for evil."
  (dolist (binding bindings)
    ;; the function, not the macro, which would take MAP for a global variable's name
    (evil-define-key* '(normal motion) map (kbd (concat "<leader>m" (car binding))) (cdr binding)))
  (when (fboundp 'which-key-add-major-mode-key-based-replacements)
    (which-key-add-major-mode-key-based-replacements mode "SPC m" "follow")))

(with-eval-after-load 'evil
  (evil-define-key '(normal motion) claude-follow-mode-map
    (kbd "gr") #'claude-follow-refresh
    (kbd "q") #'quit-window
    (kbd "RET") #'claude-follow-visit
    (kbd "TAB") #'magit-section-toggle
    (kbd "n") #'claude-follow-next-edit
    (kbd "p") #'claude-follow-previous-edit)
  (claude-follow--bind-folds claude-follow-mode-map)
  (claude-follow--bind-leader
   'claude-follow-mode claude-follow-mode-map
   '(("s" . claude-follow-status) ("x" . claude-follow-hide) ("X" . claude-follow-hide-all)
     ("u" . claude-follow-show-all) ("S" . claude-follow-toggle-status-on-done)
     ("a" . claude-follow-toggle-auto) ("v" . claude-follow-cycle-display)
     ("d" . claude-follow-diff) ("D" . claude-follow-difftastic) ("l" . claude-follow-log)
     ("L" . claude-follow-project-log) ("+" . claude-follow-more-edits))))

(defun claude-follow--sync ()
  "Read the logs, say what is new, redraw, and follow the fresh edits."
  (let* ((old claude-follow--entries)
         (rows (claude-follow--rows))
         (split (claude-follow--split rows))
         (new (car split))
         (dones (seq-filter #'claude-follow--done-p rows))
         (fresh (claude-follow--new old new)))
    (setq claude-follow--entries new
          claude-follow--archive (cdr split))
    ;; the newest fresh edit of each project keeps a mark until it expires
    (let ((now (float-time)))
      (setq claude-follow--recent-marks
            (seq-filter (lambda (m) (< now (cddr m))) claude-follow--recent-marks))
      (dolist (e fresh)
        (let* ((key (list (plist-get e :session) (plist-get e :project)))
               (mark (assoc key claude-follow--recent-marks)))
          (unless (and mark (>= (cadr mark) (plist-get e :ts)))
            (setq claude-follow--recent-marks
                  (cons (cons key (cons (plist-get e :ts) (+ now claude-follow-recent-linger)))
                        (assoc-delete-all key claude-follow--recent-marks)))))))
    (claude-follow--redraw)
    (claude-follow--on-done (claude-follow--new claude-follow--dones dones))
    (setq claude-follow--dones dones)
    (when fresh (claude-follow--pulse-projects fresh))
    (when old (claude-follow--pulse-appeared old new))
    (when (and fresh claude-follow-auto)
      (claude-follow--apply fresh)
      (claude-follow--show-later (car fresh)))
    (when-let* ((e (car fresh)))
      (message "claude-follow: %s edited %s" (plist-get e :agent)
               (file-name-nondirectory (plist-get e :file))))))

;; The hook appends one line per file, so a commit is a burst of events; they
;; are taken together a moment after the last one.
(defvar claude-follow--sync-timer nil)

(defun claude-follow--changed (&optional _event)
  "The watch fired: sync once the burst of writes is over."
  (when (timerp claude-follow--sync-timer) (cancel-timer claude-follow--sync-timer))
  (setq claude-follow--sync-timer (run-with-timer 0.2 nil #'claude-follow--sync)))

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
