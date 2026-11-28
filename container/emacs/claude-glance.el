;;; claude-glance.el --- one small file of the cockpit's state, for the phone -*- lexical-binding: t -*-

;; The desktop daemon writes `claude-glance-file' every `claude-glance-interval' seconds, only
;; while something changed: usage, running tasks, the doctor's verdict, the roles and the last
;; attention decisions.  The cockpit gateway streams it as a `glance' record (a `files' source),
;; and the remote cockpit draws it as text on the Now screen (principle 9: every visual degrades
;; to text).

;;; Code:

(require 'json)
(require 'seq)
(require 'subr-x)
(require 'claude-task-detail nil t)
(declare-function claude-board--tasks "claude-board")
(declare-function claude-board--usage "claude-board")
(declare-function claude-board--age "claude-board")
(declare-function claude-homun--roles "claude-homun")
(declare-function claude-doctor--roles "claude-doctor")
(defvar claude-doctor--data)
(defvar claude-attn--recent)
(defvar claude-doctor--data)
(defvar claude-doctor--problem)

(defcustom claude-glance-file (expand-file-name "~/claude/.homun/state/phone/glance.json")
  "Where the glance is written."
  :type 'file :group 'claude)

(defcustom claude-glance-interval 20 "Seconds between two looks." :type 'integer :group 'claude)

(defvar claude-glance--timer nil)
(defvar claude-glance--last nil "The text last written, so an unchanged glance rewrites nothing.")

(defun claude-glance--task (task)
  (list :kind (format "%s" (plist-get task :kind))
        :title (string-trim (format "%s" (or (plist-get task :desc) (plist-get task :id) "")))
        :age (claude-board--age task)
        :tracker (or (ignore-errors (claude-task-detail-tracker-id task)) :null)
        :state (symbol-name (claude-board--state task (claude-board--background-status task)))
        :last (or (ignore-errors (claude-board--last-line task)) :null)))

(defun claude-glance--checks ()
  "The doctor's role checks and the ones not ok, a dozen at most."
  (let ((checks (and (boundp 'claude-doctor--data) (alist-get 'checks claude-doctor--data)))
        (roles (and (fboundp 'claude-doctor--roles) (claude-doctor--roles))))
    (seq-take (delete-dups (append roles (seq-remove (lambda (c) (equal (alist-get 'status c) "ok"))
                                                     (append checks nil))))
              12)))

(defun claude-glance--check (check)
  (list :id (format "%s" (alist-get 'id check)) :name (format "%s" (or (alist-get 'name check) ""))
        :status (format "%s" (alist-get 'status check)) :summary (format "%s" (or (alist-get 'summary check) ""))))

;; The update, for the phone's Status line: what the desktop update card shows, or :null when idle
(defun claude-glance--update ()
  (or (and (fboundp 'claude-update-card--current)
           (let ((info (ignore-errors (claude-update-card--current))))
             (and info (not (eq (plist-get info :phase) 'done))
                  (list :phase (symbol-name (plist-get info :phase)) :since (floor (plist-get info :since))
                        :step (or (plist-get info :step) :null) :total (or (plist-get info :total) :null)
                        :rev (or (ignore-errors (claude-update-card--rev)) :null)
                        :blocked (if (ignore-errors (claude-update--restart-block)) t :false)))))
      :null))

(defun claude-glance-data ()
  "The glance as a plist."
  (let ((usage (ignore-errors (claude-board--usage))))
    (list :usage (and usage (list :five (nth 0 usage) :five_reset (nth 1 usage)
                                  :seven (nth 2 usage) :seven_reset (nth 3 usage)))
          :update (claude-glance--update)
          :tasks (vconcat (mapcar #'claude-glance--task
                                  (seq-take (ignore-errors (claude-board--tasks)) 12)))
          :doctor (list :ok (if (and (bound-and-true-p claude-doctor--data)
                                           (not (bound-and-true-p claude-doctor--problem))
                                           (alist-get 'checks claude-doctor--data)
                                           (seq-every-p (lambda (c) (equal (alist-get 'status c) "ok"))
                                                        (alist-get 'checks claude-doctor--data)))
                                      t :false)
                        :problem (or (bound-and-true-p claude-doctor--problem) :null))
          :checks (vconcat (mapcar #'claude-glance--check (claude-glance--checks)))
          :roles (vconcat (mapcar (lambda (r) (format "%s" (car r)))
                                  (ignore-errors (claude-homun--roles))))
          :attn (vconcat (mapcar (lambda (r) (list :level (format "%s" (nth 1 r)) :step (format "%s" (nth 2 r))
                                                   :text (truncate-string-to-width (format "%s" (nth 3 r)) 80)))
                                 (seq-take (and (boundp 'claude-attn--recent) claude-attn--recent) 5))))))

(defun claude-glance-write ()
  "Write the glance when it differs from the last one."
  (let ((text (json-serialize (claude-glance-data) :null-object :null :false-object :false)))
    (unless (equal text claude-glance--last)
      (setq claude-glance--last text)
      (make-directory (file-name-directory claude-glance-file) t)
      (let ((tmp (concat claude-glance-file ".tmp")))
        (write-region text nil tmp nil 'quiet)
        (rename-file tmp claude-glance-file t)))))

(defun claude-glance-start ()
  "Write the glance now and then on a timer."
  (when claude-glance--timer (cancel-timer claude-glance--timer))
  (setq claude-glance--timer
        (run-with-timer 1 claude-glance-interval
                        (lambda () (with-demoted-errors "claude-glance: %S" (claude-glance-write))))))

(provide 'claude-glance)
;;; claude-glance.el ends here
