;;; claude-run-detail.el --- Detail of an agent run: status, model, latest report, transcript -*- lexical-binding: t -*-

;; The twin of `claude-task-detail' for an agent: its row of the links store, the model and
;; latest line read from its transcript, and pills Back, Stop (hold to confirm) and Retry.
;; Stop goes through `claude-tasks--stop', Retry asks the manager on the bus; the view only
;; redraws from the store, it keeps no state of its own.

;;; Code:

(require 'subr-x)
(require 'seq)
(require 'homun-button)

(declare-function claude-header "claude")
(declare-function claude-confirm "claude")
(declare-function claude-links-row "claude-links")
(declare-function claude-links-open-agent "claude-links")
(declare-function claude-tasks--stop "claude-tasks")
(declare-function claude-board--tasks "claude-board")
(declare-function claude-board--last-line "claude-board")
(declare-function claude-bus-tell "claude-bus")
(defvar claude-tasks-events)

(defvar claude-run-detail-buffer "*claude-run*")
(defvar-local claude-run-detail--agent nil "The agent id this buffer shows.")
(defvar-local claude-run-detail--label nil "The title the caller gave the run.")

(defvar claude-run-detail--models (make-hash-table :test #'equal) "Transcript file to (STAMP . MODEL).")

(defun claude-run-detail-model (file)
  "The model the transcript FILE last names, read from its tail and cached by size
and mtime."
  (when-let* ((attrs (and file (file-attributes file))))
    (let ((stamp (cons (file-attribute-size attrs) (file-attribute-modification-time attrs)))
          (hit (gethash file claude-run-detail--models)))
      (if (equal (car hit) stamp)
          (cdr hit)
        (let ((model (with-temp-buffer
                       (insert-file-contents file nil (max 0 (- (car stamp) 16384)))
                       (goto-char (point-max))
                       (and (re-search-backward "\"model\": ?\"\\([^\"]+\\)\"" nil t) (match-string 1)))))
          (puthash file (cons stamp model) claude-run-detail--models)
          model)))))

(defun claude-run-detail-data (agent &optional label)
  "The plist of AGENT's run: :title :status :kind :task :model :latest :transcript."
  (require 'claude-board nil t)
  (let* ((row (and (fboundp 'claude-links-row) (claude-links-row agent)))
         (file (alist-get 'transcript row))
         (latest (or (and file (ignore-errors (claude-board--last-line (list :transcript file))))
                     (alist-get 'summary row))))
    (list :id agent :title (or (alist-get 'desc row) label agent)
          :status (or (alist-get 'status row) "unknown")
          :kind (alist-get 'kind row) :task (alist-get 'task row)
          :model (claude-run-detail-model file) :latest latest :transcript file)))

(defun claude-run-detail--field (label value)
  (when (and value (not (equal value "")))
    (insert (propertize (format "%-10s" label) 'face 'shadow) (format "%s" value) "\n")))

(defun claude-run-detail--pill (label role action)
  (insert (homun-button label role action) " "))

(defun claude-run-detail--stop-pill ()
  "The Stop pill: hold to confirm when widgetry is there, else a plain button that
asks."
  (if (and (fboundp 'widgetry-mode) (require 'widgetry-button nil t))
      (widget-create 'widgetry-button :value " Stop " :confirm 'hold
                     :help-echo "Hold to stop this run"
                     :notify (lambda (&rest _) (claude-run-detail-stop t)))
    (claude-run-detail--pill "Stop" 'danger #'claude-run-detail-stop)))

(defun claude-run-detail-insert (data)
  "Insert the run DATA (see `claude-run-detail-data') at point."
  (insert (propertize (format "%s" (plist-get data :title)) 'face 'bold) "\n\n")
  (claude-run-detail--pill "Back" 'secondary #'claude-run-detail-back)
  (claude-run-detail--stop-pill)
  (insert " ")
  (claude-run-detail--pill "Retry" 'secondary #'claude-run-detail-retry)
  (insert "\n\n")
  (claude-run-detail--field "Status" (plist-get data :status))
  (claude-run-detail--field "Model" (plist-get data :model))
  (claude-run-detail--field "Kind" (plist-get data :kind))
  (claude-run-detail--field "Task" (plist-get data :task))
  (insert (propertize "\nLatest report\n" 'face '(shadow bold))
          (or (plist-get data :latest) (propertize "Nothing reported yet." 'face 'shadow)) "\n")
  (when-let* ((file (plist-get data :transcript)))
    (insert (propertize "\nTranscript\n" 'face '(shadow bold)))
    (insert-text-button file 'action (lambda (_) (claude-run-detail-transcript)) 'follow-link t)
    (insert "\n")))

(defvar claude-run-detail-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "q" #'claude-run-detail-back)
    (define-key map "x" #'claude-run-detail-stop)
    (define-key map "r" #'claude-run-detail-retry)
    (define-key map (kbd "RET") #'claude-run-detail-transcript)
    map)
  "Keys of `claude-run-detail-mode'.")

(define-derived-mode claude-run-detail-mode special-mode "Run"
  "The detail of an agent run: q back, x stop, r retry, RET transcript, g redraw.")

(defun claude-run-detail--redraw ()
  (let ((inhibit-read-only t) (here (point)))
    (erase-buffer)
    (claude-run-detail-insert (claude-run-detail-data claude-run-detail--agent claude-run-detail--label))
    (when (fboundp 'widget-setup) (widget-setup))
    (goto-char (min here (point-max)))))

(defun claude-run-detail-back ()
  "Leave the detail."
  (interactive)
  (quit-window t))

(defun claude-run-detail--task ()
  "The board task of this run when the board lists it, else a bare one."
  (or (and (fboundp 'claude-board--tasks)
           (seq-find (lambda (tk) (equal (plist-get tk :id) claude-run-detail--agent))
                     (ignore-errors (claude-board--tasks))))
      (list :id claude-run-detail--agent :desc claude-run-detail--label)))

(defun claude-run-detail-stop (&optional confirmed)
  "Stop the run, after asking unless CONFIRMED (the hold button confirms by
itself)."
  (interactive)
  (when (or confirmed (claude-confirm (format "Stop %s? " claude-run-detail--label)))
    (claude-tasks--stop (claude-run-detail--task))
    (revert-buffer)))

(defun claude-run-detail-retry ()
  "Ask the manager to run this agent again."
  (interactive)
  (require 'claude-bus)
  (claude-bus-tell 'manager "tasks-retry"
                   (format "tasks-retry: %s %s" claude-run-detail--agent claude-run-detail--label)
                   claude-tasks-events)
  (message "Asked the manager to retry %s" claude-run-detail--agent))

(defun claude-run-detail-transcript ()
  "Open the run's transcript."
  (interactive)
  (claude-links-open-agent claude-run-detail--agent))

;;;###autoload
(defun claude-run-detail-open (agent &optional label)
  "Show the detail of the agent run with id AGENT, LABEL its title when the store
has none."
  (let ((buffer (get-buffer-create claude-run-detail-buffer)))
    (with-current-buffer buffer
      (claude-run-detail-mode)
      (setq claude-run-detail--agent agent claude-run-detail--label label)
      (setq-local revert-buffer-function (lambda (&rest _) (claude-run-detail--redraw)))
      (setq header-line-format (claude-header "Agent run" "x stop · r retry · RET transcript · gr redraw · q back"))
      (claude-run-detail--redraw))
    (pop-to-buffer-same-window buffer)))

(provide 'claude-run-detail)
;;; claude-run-detail.el ends here
