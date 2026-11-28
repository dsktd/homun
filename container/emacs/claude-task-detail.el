;;; claude-task-detail.el --- Detail of a board task: its tracker item and agent run -*- lexical-binding: t -*-

;; Tapping a task on the board (desktop) or Board view (phone) opens this view: the tracker
;; item the agent works on (title, state, priority, tags, body, notes, workspace and branches)
;; and the agent run itself (status, latest report line), with pills Back, Next, Done and Drop.
;; The item is found from the agent's row in the links store or a "#ID" in its description.
;; One renderer (`claude-task-detail-insert') serves both: the desktop gets its data from
;; the daemon, the phone from the API entries `tracker show' and `tracker state'.

(require 'subr-x)
(require 'seq)
(require 'json)
(require 'homun-button)

(defvar claude-homun-tracker-file)
(declare-function claude-header "claude")
(declare-function claude-confirm "claude")
(declare-function claude-links-row "claude-links")
(declare-function claude-board--state "claude-board")
(declare-function claude-board--background-status "claude-board")
(declare-function claude-board--last-line "claude-board")

(declare-function claude-tracker-show "claude-tracker")
(declare-function claude-tracker-state "claude-tracker")

(defconst claude-task-detail-states '("next" "done" "drop")
  "The states the pills set, as `tracker state' takes them.")

(defun claude-task-detail-file ()
  "The tracker's Org file."
  (or (getenv "TRACKER_FILE")
      (and (boundp 'claude-homun-tracker-file) claude-homun-tracker-file)
      (expand-file-name "~/claude/context/tracker.org")))

(defun claude-task-detail-tracker-id (task)
  "The tracker id the agent TASK (a board task plist) works on, or nil."
  (let ((row (and (fboundp 'claude-links-row) (plist-get task :id)
                  (claude-links-row (plist-get task :id)))))
    (cond ((and row (equal (alist-get 'kind row) "tracker"))
           (let ((id (alist-get 'task row)))
             (if (numberp id) id (and (stringp id) (string-match "\\`#?\\([0-9]+\\)\\'" id)
                                      (string-to-number (match-string 1 id))))))
          ((string-match "#\\([0-9]+\\)" (concat (and row (alist-get 'desc row)) " "
                                                 (plist-get task :desc)))
           (string-to-number (match-string 1 (concat (and row (alist-get 'desc row)) " "
                                                     (plist-get task :desc))))))))

(defun claude-task-detail--branches (workspace)
  "\"repo: branch\" for each worktree under ~/claude/WORKSPACE."
  (when (and (stringp workspace) (not (string-empty-p workspace)))
    (let ((root (expand-file-name workspace "~/claude")))
      (delq nil
            (mapcar (lambda (dir)
                      (when (file-exists-p (expand-file-name ".git" dir))
                        (let ((branch (ignore-errors
                                        (car (process-lines "git" "-C" dir "branch" "--show-current")))))
                          (format "%s: %s" (file-name-nondirectory dir) (or branch "detached")))))
                    (and (file-directory-p root)
                         (directory-files root t directory-files-no-dot-files-regexp)))))))

(defun claude-task-detail-show-json (id)
  "Entry ID of the tracker as JSON, with the branches of its workspace."
  (require 'claude-tracker)
  (let ((entry (claude-tracker-show (claude-task-detail-file) id)))
    (json-serialize
     (append entry (list :branches (vconcat (claude-task-detail--branches (plist-get entry :workspace)))))
     :null-object :null :false-object :false)))

(defun claude-task-detail-set-state (id state)
  "Set tracker entry ID to STATE (one of `claude-task-detail-states'); ID."
  (unless (member state claude-task-detail-states)
    (error "State %s is not one of %s" state (string-join claude-task-detail-states ", ")))
  (require 'claude-tracker)
  (claude-tracker-state (claude-task-detail-file) id state))

(defun claude-task-detail--list (value)
  "VALUE as a list, whether it came as a vector or a list."
  (append value nil))

(defun claude-task-detail-parse (json)
  "The plist a `tracker show' JSON string holds, lists for arrays and nil for null."
  (json-parse-string json :object-type 'plist :array-type 'list :null-object nil))

(defun claude-task-detail-local (task)
  "The detail data of the board TASK, read in this daemon."
  (let ((id (claude-task-detail-tracker-id task)))
    (list :id id
          :tracker (and id (ignore-errors (claude-task-detail-parse (claude-task-detail-show-json id))))
          :agent (list :title (string-trim (or (plist-get task :desc) ""))
                       :kind (format "%s" (plist-get task :kind))
                       :state (symbol-name (claude-board--state task (claude-board--background-status task)))
                       :last (claude-board--last-line task)))))

;;; Rendering

(defun claude-task-detail--label (text)
  (insert "\n" (propertize text 'face '(shadow bold)) "\n"))

(defun claude-task-detail--field (label value)
  (when (and value (not (equal value "")))
    (insert (propertize (format "%-10s" label) 'face 'shadow) value "\n")))

(defun claude-task-detail-insert (data actions &optional phone)
  "Insert the detail DATA (see `claude-task-detail-local') at point.
ACTIONS is a plist of functions of no arguments: :back, :next, :done, :drop.
PHONE pads the pills to thumb height."
  (let* ((item (plist-get data :tracker))
         (agent (plist-get data :agent))
         (title (or (plist-get item :title) (plist-get agent :title) "Task")))
    (insert (propertize (if (plist-get item :id) (format "#%s " (plist-get item :id)) "") 'face 'shadow)
            (propertize title 'face 'bold) "\n")
    (when item
      (claude-task-detail--label "Tracker")
      (claude-task-detail--field "State" (plist-get item :state))
      (claude-task-detail--field "Priority" (plist-get item :priority))
      (claude-task-detail--field "Tags" (string-join (plist-get item :tags) " "))
      (claude-task-detail--field "Workspace" (plist-get item :workspace))
      (dolist (branch (plist-get item :branches))
        (claude-task-detail--field "Branch" branch))
      (unless (string-empty-p (or (plist-get item :body) ""))
        (claude-task-detail--label "Body")
        (insert (plist-get item :body) "\n"))
      (when (plist-get item :notes)
        (claude-task-detail--label "Notes")
        (dolist (note (plist-get item :notes))
          (insert (propertize (or (plist-get note :time) "") 'face 'shadow) "\n"
                  (or (plist-get note :text) "") "\n"))))
    (unless item
      (claude-task-detail--label "Tracker")
      (insert (propertize "No tracker item is linked to this task.\n" 'face 'shadow)))
    (when agent
      (claude-task-detail--label "Agent run")
      (claude-task-detail--field "Status" (plist-get agent :state))
      (claude-task-detail--field "Kind" (plist-get agent :kind))
      (claude-task-detail--field "Latest" (plist-get agent :last)))
    (claude-task-detail--label "Actions")
    (let ((pill (lambda (label role key)
                  (homun-button label role (plist-get actions key) phone))))
      (insert (funcall pill "Back" 'secondary :back))
      (when item
        (insert " " (funcall pill "Next" 'primary :next)
                " " (funcall pill "Done" 'primary :done)
                " " (funcall pill "Drop" 'danger :drop)))
      (insert "\n"))))

;;; Desktop

(defvar claude-task-detail-buffer "*claude-task*")
(defvar-local claude-task-detail--data nil "The data this buffer shows.")
(defvar-local claude-task-detail--task nil "The board task this buffer shows.")

(defvar claude-task-detail-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "q" #'claude-task-detail-back)
    (define-key map "n" #'claude-task-detail-next)
    (define-key map "d" #'claude-task-detail-done)
    (define-key map "x" #'claude-task-detail-drop)
    map)
  "Keys of `claude-task-detail-mode'.")

(define-derived-mode claude-task-detail-mode special-mode "Task"
  "The detail of a board task: q back, n next, d done, x drop, g redraw.")

(with-eval-after-load 'evil
  (declare-function evil-define-key* "evil-core")
  (evil-define-key* '(normal motion) claude-task-detail-mode-map
    "q" #'claude-task-detail-back "n" #'claude-task-detail-next
    "d" #'claude-task-detail-done "x" #'claude-task-detail-drop))

(defun claude-task-detail--redraw ()
  (let ((inhibit-read-only t) (data (claude-task-detail-local claude-task-detail--task)))
    (setq claude-task-detail--data data)
    (erase-buffer)
    (claude-task-detail-insert
     data (list :back #'claude-task-detail-back :next #'claude-task-detail-next
                :done #'claude-task-detail-done :drop #'claude-task-detail-drop))
    (goto-char (point-min))))

(defun claude-task-detail-back ()
  "Leave the detail, back to the board."
  (interactive)
  (quit-window t))

(defun claude-task-detail--set (state)
  (let ((id (plist-get claude-task-detail--data :id)))
    (unless id (user-error "No tracker item is linked to this task"))
    (claude-task-detail-set-state id state)
    (revert-buffer)
    (message "#%s: %s" id state)))

(defun claude-task-detail-next () "Set the item to NEXT." (interactive) (claude-task-detail--set "next"))
(defun claude-task-detail-done () "Set the item to DONE." (interactive) (claude-task-detail--set "done"))

(defun claude-task-detail-drop ()
  "Set the item to DROP, after asking."
  (interactive)
  (when (claude-confirm (format "Drop #%s? " (plist-get claude-task-detail--data :id)))
    (claude-task-detail--set "drop")))

;;;###autoload
(defun claude-task-detail-open (task)
  "Show the detail of the board TASK."
  (let ((buffer (get-buffer-create claude-task-detail-buffer)))
    (with-current-buffer buffer
      (claude-task-detail-mode)
      (setq claude-task-detail--task task)
      (setq-local revert-buffer-function (lambda (&rest _) (claude-task-detail--redraw)))
      (setq header-line-format (claude-header "Task" "n next · d done · x drop · gr redraw · q back"))
      (claude-task-detail--redraw))
    (pop-to-buffer-same-window buffer)))

(provide 'claude-task-detail)
;;; claude-task-detail.el ends here
