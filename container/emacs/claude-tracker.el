;;; claude-tracker.el --- The org-mode issue tracker behind the tracker CLI -*- lexical-binding: t -*-

;; Each verb of /usr/local/bin/tracker (container/tracker) is one
;; `emacsclient --eval' form on a tracker file: a top-level heading per repo,
;; an entry per issue under it with its ID property, sub-issues as child
;; entries, comments as notes in the LOGBOOK drawer. Readers return what `json-serialize' takes
;; (plists, vectors, :null); writers save the file and return the entry's id.

(require 'org)
(require 'org-element)

(defvar claude-tracker--file nil "The file the current `claude-tracker--with-file' buffer was read from.")

(defmacro claude-tracker--with-file (file &rest body)
  "Run BODY in a scratch buffer holding FILE, with the layout the tracker writes.
The file is read from disk, never visited: a verb cannot prompt to reread it or
save what the user has typed in their own buffer."
  (declare (indent 1))
  `(let ((claude-tracker--file (file-truename ,file)))
     (with-temp-buffer
       (when (file-exists-p claude-tracker--file)
         (insert-file-contents claude-tracker--file))
       (org-mode)
       (let ((org-adapt-indentation t)
             (org-log-done 'time)
             (org-log-into-drawer t)
             (org-log-states-order-reversed t))
         ,@body))))

(defun claude-tracker--save ()
  "Write the buffer to `claude-tracker--file' through a temporary file and a
rename."
  (let ((tmp (concat claude-tracker--file ".tmp")))
    (make-directory (file-name-directory claude-tracker--file) t)
    (write-region (point-min) (point-max) tmp nil 'silent)
    (when (file-exists-p claude-tracker--file)
      (set-file-modes tmp (file-modes claude-tracker--file)))
    (rename-file tmp claude-tracker--file t)))

(defmacro claude-tracker--writing (file &rest body)
  "Run BODY in FILE like `claude-tracker--with-file', then save it."
  (declare (indent 1))
  `(claude-tracker--with-file ,file
     (prog1 (progn ,@body)
       (claude-tracker--save))))

(defun claude-tracker--now ()
  (format-time-string (org-time-stamp-format t t)))

(defun claude-tracker--id ()
  "The id of the entry at point, or nil for a repo heading."
  (let ((id (org-entry-get nil "ID")))
    (and id (string-to-number id))))

(defun claude-tracker--goto (id)
  "Move to the entry whose ID is ID."
  (let ((pos (org-find-property "ID" (number-to-string id))))
    (unless pos
      (error "No entry with id %s" id))
    (goto-char pos)))

(defun claude-tracker--goto-repo (repo)
  "Move to the end of the top-level heading REPO's subtree, making it when missing."
  (goto-char (point-min))
  (if (re-search-forward (format "^\\* %s[ \t]*$" (regexp-quote repo)) nil t)
      (org-end-of-subtree t t)
    (goto-char (point-max))
    (unless (bolp)
      (insert "\n"))
    (insert "* " repo "\n")))

(defun claude-tracker--text (string)
  (and string (substring-no-properties string)))

(defun claude-tracker--entry ()
  "The entry at point as a plist."
  (let* ((element (org-element-at-point))
         (priority (org-element-property :priority element))
         (closed (org-element-property :closed element)))
    (list :id (claude-tracker--id)
          :state (or (claude-tracker--text (org-element-property :todo-keyword element)) :null)
          :priority (if priority (char-to-string priority) :null)
          :title (claude-tracker--text (org-element-property :raw-value element))
          :repo (save-excursion
                  (while (org-up-heading-safe))
                  (claude-tracker--text (org-get-heading t t t t)))
          :parent (or (save-excursion
                        (and (org-up-heading-safe) (claude-tracker--id)))
                      :null)
          :tags (vconcat (mapcar #'claude-tracker--text (org-element-property :tags element)))
          :owner (or (org-entry-get nil "OWNER") :null)
          :workspace (or (org-entry-get nil "WORKSPACE") :null)
          :milestone (or (org-entry-get nil "MILESTONE") :null)
          :created (or (org-entry-get nil "CREATED") :null)
          :closed (if closed (claude-tracker--text (org-element-property :raw-value closed)) :null))))

(defun claude-tracker--body ()
  "The text of the entry at point after its drawers, up to its first child."
  (save-excursion
    (org-end-of-meta-data t)
    (string-trim
     (org-remove-indentation
      (buffer-substring-no-properties (point) (org-entry-end-position))))))

(defun claude-tracker--notes ()
  "The LOGBOOK notes of the entry at point, newest first."
  (save-excursion
    (let ((end (org-entry-end-position))
          notes)
      (when (re-search-forward "^[ \t]*:LOGBOOK:[ \t]*$" end t)
        (let ((drawer-end (save-excursion
                            (and (re-search-forward "^[ \t]*:END:[ \t]*$" end t)
                                 (line-beginning-position)))))
          (while (re-search-forward "^[ \t]*- Note taken on \\(\\[[^]]+\\]\\) \\\\\\\\$" drawer-end t)
            (let ((time (match-string-no-properties 1))
                  (start (line-beginning-position 2))
                  (stop (if (re-search-forward "^[ \t]*- " drawer-end t)
                            (line-beginning-position)
                          drawer-end)))
              (goto-char stop)
              (push (list :time time
                          :text (org-remove-indentation
                                 (string-trim-right (buffer-substring-no-properties start stop))))
                    notes)))))
      (vconcat (nreverse notes)))))

(defun claude-tracker--children ()
  "The entries one level under the entry at point."
  (let ((level (1+ (org-current-level)))
        positions)
    ;; `org-map-entries' narrows to the tree, which would hide the repo heading
    (org-map-entries (lambda ()
                       (when (= (org-current-level) level)
                         (push (point) positions)))
                     nil 'tree)
    (vconcat (mapcar (lambda (pos)
                       (save-excursion
                         (goto-char pos)
                         (claude-tracker--entry)))
                     (nreverse positions)))))

(defun claude-tracker--matches (entry state tag repo id)
  (let ((entry-state (plist-get entry :state)))
    (and (or (null state)
             (pcase state
               ("all" t)
               ("open" (not (member entry-state org-done-keywords)))
               ("closed" (member entry-state org-done-keywords))
               (_ (equal entry-state (upcase state)))))
         (or (null tag) (seq-contains-p (plist-get entry :tags) tag))
         (or (null repo) (equal (plist-get entry :repo) repo))
         (or (null id) (eql (plist-get entry :id) id)))))

(defvar claude-tracker--listed nil
  "(STAMP DONE-KEYWORDS ENTRIES) of the last file listed:
`claude-tracker--entries'.")

(defun claude-tracker--entries (file)
  "Every entry of FILE as (DONE-KEYWORDS ENTRIES), parsed only when the file
changed.
The file is what the status views poll (every 10 s) and a parse is 0.2 s of a
daemon the user types in, so the last answer is kept while the file's name, time
and size stand."
  (let* ((name (file-truename file))
         (attributes (file-attributes name))
         (stamp (list name (file-attribute-modification-time attributes)
                      (file-attribute-size attributes))))
    (unless (and attributes (equal stamp (car claude-tracker--listed)))
      (setq claude-tracker--listed
            (cons stamp
                  (claude-tracker--with-file file
                    (let (entries)
                      (org-map-entries (lambda ()
                                         (when (claude-tracker--id)
                                           (push (claude-tracker--entry) entries))))
                      (list org-done-keywords (nreverse entries)))))))
    (cdr claude-tracker--listed)))

(defun claude-tracker-list (file &optional state tag repo id)
  "The entries of FILE with STATE, TAG, REPO and ID.
STATE is \"open\", \"closed\", \"all\" or a keyword."
  (pcase-let ((`(,org-done-keywords ,entries) (claude-tracker--entries file)))
    (vconcat (seq-filter (lambda (entry) (claude-tracker--matches entry state tag repo id))
                         entries))))

(defun claude-tracker-link (file id)
  "Project bare-clone name, title and workspace of entry ID in FILE, one per line.
The clone is the :REPO: property of the top-level heading, else its name."
  (claude-tracker--with-file file
    (claude-tracker--goto id)
    (let ((title (org-get-heading t t t t))
          (workspace (or (org-entry-get nil "WORKSPACE") "")))
      (setq title (claude-tracker--text title))
      (while (org-up-heading-safe))
      (format "%s\n%s\n%s"
              (claude-tracker--text (or (org-entry-get nil "REPO") (org-get-heading t t t t)))
              title
              workspace))))

(defun claude-tracker-show (file id)
  "Entry ID of FILE with its body, notes and children."
  (claude-tracker--with-file file
    (claude-tracker--goto id)
    (append (claude-tracker--entry)
            (list :body (claude-tracker--body)
                  :notes (claude-tracker--notes)
                  :children (claude-tracker--children)))))

(defun claude-tracker--archive-file (file)
  "The archive beside FILE."
  (expand-file-name "archive.org" (file-name-directory file)))

(defun claude-tracker--max-id ()
  "The highest id of the buffer's file and of the archive beside it."
  (let ((max 0)
        (archive (claude-tracker--archive-file claude-tracker--file)))
    (org-map-entries (lambda ()
                       (setq max (max max (or (claude-tracker--id) 0)))))
    (if (and (file-exists-p archive)
             (not (equal (file-truename archive) claude-tracker--file)))
        (max max (claude-tracker--with-file archive (claude-tracker--max-id)))
      max)))

(defun claude-tracker--insert-body (text)
  "Insert TEXT after the entry's drawers, indented like them."
  (org-end-of-meta-data t)
  (let ((indent (make-string (1+ (org-current-level)) ?\s)))
    (dolist (line (split-string text "\n"))
      (insert (if (string-empty-p line) "" (concat indent line)) "\n"))))

(defun claude-tracker-add (file repo title &optional body priority tags parent)
  "Add a TODO entry TITLE to FILE under REPO, or under entry PARENT; its id.
PRIORITY is a letter, TAGS a vector of strings, BODY text."
  (claude-tracker--writing file
    (let ((id (1+ (claude-tracker--max-id)))
          (level 2))
      (if parent
          (progn (claude-tracker--goto parent)
                 (setq level (1+ (org-current-level)))
                 (org-end-of-subtree t t))
        (claude-tracker--goto-repo repo))
      (unless (bolp)
        (insert "\n"))
      (insert (make-string level ?*) " TODO " title "\n")
      (forward-line -1)
      (when priority
        (org-priority (upcase (string-to-char priority))))
      (when tags
        (org-set-tags (append tags nil)))
      (org-set-property "ID" (number-to-string id))
      (org-set-property "CREATED" (claude-tracker--now))
      (when body
        (claude-tracker--insert-body body))
      id)))

(defun claude-tracker-state (file id state)
  "Set entry ID of FILE to STATE, a keyword of the file."
  (claude-tracker--writing file
    (claude-tracker--goto id)
    (let ((state (upcase state)))
      (unless (member state org-todo-keywords-1)
        (error "No state %s; the file has %s" state (string-join org-todo-keywords-1 " ")))
      (org-todo state))
    id))

(defun claude-tracker-note (file id text)
  "Add TEXT as the newest note of entry ID in FILE."
  (claude-tracker--writing file
    (claude-tracker--goto id)
    (goto-char (org-log-beginning t))
    (let ((indent (make-string (current-indentation) ?\s)))
      (insert indent "- Note taken on " (claude-tracker--now) " \\\\\n")
      (dolist (line (split-string text "\n"))
        (insert (if (string-empty-p line) "" (concat indent "  " line)) "\n")))
    id))

(defun claude-tracker-set (file id property value)
  "Set PROPERTY of entry ID in FILE to VALUE; PRIORITY and TITLE set those."
  (claude-tracker--writing file
    (claude-tracker--goto id)
    (pcase (upcase property)
      ("PRIORITY" (org-priority (upcase (string-to-char value))))
      ("TITLE" (org-edit-headline value))
      (property (org-set-property property value)))
    id))

(defun claude-tracker-tag (file id action tag)
  "Add or remove TAG on entry ID in FILE; ACTION is \"add\" or \"del\"."
  (claude-tracker--writing file
    (claude-tracker--goto id)
    (let ((tags (org-get-tags nil t)))
      (org-set-tags (pcase action
                      ("add" (delete-dups (cons tag tags)))
                      ("del" (delete tag tags))
                      (_ (error "No tag action %s" action)))))
    id))

(defconst claude-tracker--archive-days 14
  "Days a DONE or DROP entry stays in the tracker before it is archived.")

(defun claude-tracker--archivable-p ()
  "Whether the top-level entry at point is closed for longer than the archive age."
  (let ((closed (org-entry-get nil "CLOSED")))
    (and (= (org-current-level) 2)
         (member (org-get-todo-state) org-done-keywords)
         closed
         (time-less-p (org-time-string-to-time closed)
                      (time-subtract nil (* claude-tracker--archive-days 86400))))))

(defun claude-tracker-archive (file)
  "Move closed top-level entries of FILE older than 14 days to archive.org.
They keep their subtrees and repo; the archive is made when missing.
Returns the moved ids."
  (claude-tracker--writing file
    (let ((archive (claude-tracker--archive-file file))
          (kill-ring nil)
          markers ids)
      (org-map-entries (lambda ()
                         (when (claude-tracker--archivable-p)
                           (push (point-marker) markers))))
      (dolist (marker (nreverse markers))
        (goto-char marker)
        (let ((repo (save-excursion
                      (org-up-heading-safe)
                      (org-get-heading t t t t))))
          (push (claude-tracker--id) ids)
          (org-cut-subtree)
          (claude-tracker--writing archive
            (when (= (buffer-size) 0)
              (insert "#+TODO: TODO NEXT DOING WAIT | DONE DROP\n#+STARTUP: overview logdrawer\n")
              (org-mode))
            (claude-tracker--goto-repo repo)
            (org-paste-subtree 2))))
      (vconcat (nreverse ids)))))

(provide 'claude-tracker)
;;; claude-tracker.el ends here
