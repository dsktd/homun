;;; homun-stage-rows-test.el --- ERT for the stage rows: open, hover, drag -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -L container/emacs/widgetry -l tests/el/homun-stage-rows-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'homun-stage-rows)
(require 'claude-tracker)

(defconst homun-stage-rows-test--todos
  "* Work\n** TODO Alpha job\n** TODO Beta job #7\n** TODO Gamma job\n:PROPERTIES:\n:AGENT: [[homun-agent:a1]]\n:END:\n")

(defconst homun-stage-rows-test--tracker
  "#+TODO: TODO NEXT DOING WAIT | DONE DROP\n* repo\n** TODO Beta job :x:\n   :PROPERTIES:\n   :ID:       7\n   :END:\n")

(defmacro homun-stage-rows-test--with (&rest body)
  `(let* ((dir (file-name-as-directory (make-temp-file "rows" t)))
          (homun-stage-dir dir)
          (homun-stage-scenes (make-hash-table :test #'equal))
          (claude-todos-dir dir)
          (tracker (expand-file-name "tracker.org" dir))
          (transcript (expand-file-name "run.jsonl" dir))
          (claude-links-file (expand-file-name "links.jsonl" dir))
          (claude-links--rows nil)
          (process-environment (cons (concat "TRACKER_FILE=" tracker) process-environment)))
     (with-temp-file (claude-todos-file) (insert homun-stage-rows-test--todos))
     (with-temp-file tracker (insert homun-stage-rows-test--tracker))
     (with-temp-file transcript
       (insert "{\"type\":\"system\"}\n{\"type\":\"assistant\",\"message\":{\"model\":\"claude-test-9\",\"content\":[{\"type\":\"text\",\"text\":\"Nearly done\"}]}}\n"))
     (with-temp-file claude-links-file
       (insert (format "{\"agent\":\"a1\",\"kind\":\"todo\",\"desc\":\"Gamma job\",\"status\":\"running\",\"transcript\":%S}\n" transcript)))
     (cl-letf (((symbol-function 'homun-stage-work-running) #'ignore))
     (unwind-protect
         (progn (homun-stage-work-sync)
                (set-window-buffer (selected-window) (homun-stage-buffer-name homun-stage-work-id))
                ,@body)
       (dolist (b (buffer-list))
         (when (string-match-p "\\`\\*stage " (buffer-name b)) (kill-buffer b)))
       (delete-directory dir t)))))

(defun homun-stage-rows-test--labels ()
  (mapcar (lambda (r) (plist-get r :label)) (homun-stage-rows-list)))

(defun homun-stage-rows-test--pos (label)
  "A buffer position on the row LABEL (or the Done target for `done')."
  (with-current-buffer (homun-stage-buffer-name homun-stage-work-id)
    (save-excursion
      (goto-char (point-min))
      (search-forward "Items")
      (search-forward (if (eq label 'done) "Done: drop here" label))
      (match-beginning 0))))

(defun homun-stage-rows-test--event (type from to)
  "A TYPE mouse event from row FROM to row TO, as the command loop makes them."
  (let ((w (selected-window)))
    (list type (list w (homun-stage-rows-test--pos from) '(0 . 0) 0)
          (list w (homun-stage-rows-test--pos to) '(0 . 0) 0))))

(ert-deftest homun-stage-rows-drawn-under-scene ()
  (homun-stage-rows-test--with
   (with-current-buffer (homun-stage-buffer-name homun-stage-work-id)
     (should (get-text-property (homun-stage-rows-test--pos "Alpha job") 'homun-row))
     (should (eq 'done (get-text-property (homun-stage-rows-test--pos 'done) 'homun-row))))))

(ert-deftest homun-stage-rows-hover-shows-report-and-model ()
  (homun-stage-rows-test--with
   (let ((text (homun-stage-rows--echo (selected-window) nil (homun-stage-rows-test--pos "Gamma job"))))
     (should (string-match-p "Nearly done" text))
     (should (string-match-p "claude-test-9" text)))))

(ert-deftest homun-stage-rows-hover-runs-no-process ()
  (homun-stage-rows-test--with
   (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (error "subprocess")))
             ((symbol-function 'call-process) (lambda (&rest _) (error "subprocess"))))
     (should (stringp (homun-stage-rows--echo (selected-window) nil (homun-stage-rows-test--pos "Gamma job")))))))

(ert-deftest homun-stage-rows-open-tracker-or-run ()
  (homun-stage-rows-test--with
   (let (opened)
     (cl-letf (((symbol-function 'claude-task-detail-open) (lambda (task) (push (list 'task task) opened)))
               ((symbol-function 'claude-run-detail-open) (lambda (id _l) (push (list 'run id) opened))))
       (with-current-buffer (homun-stage-buffer-name homun-stage-work-id)
         (goto-char (homun-stage-rows-test--pos "Beta job"))
         (homun-stage-rows-open-at-point)
         (goto-char (homun-stage-rows-test--pos "Gamma job"))
         (homun-stage-rows-open-at-point)))
     (should (equal 'task (car (cadr opened))))
     (should (equal '(run "a1") (car opened))))))

(ert-deftest homun-stage-rows-drag-reorders ()
  (homun-stage-rows-test--with
   (homun-stage-rows-drag (homun-stage-rows-test--event 'drag-mouse-1 "Gamma job" "Alpha job"))
   (should (equal '("Gamma job" "Alpha job" "Beta job #7") (homun-stage-rows-test--labels)))
   (should (< (homun-stage-rows-test--pos "Gamma job") (homun-stage-rows-test--pos "Alpha job")))
   (homun-stage-rows-drag (homun-stage-rows-test--event 'drag-mouse-1 "Gamma job" "Beta job"))
   (should (equal '("Alpha job" "Beta job #7" "Gamma job") (homun-stage-rows-test--labels)))))

(ert-deftest homun-stage-rows-drag-to-done-uses-tracker ()
  (homun-stage-rows-test--with
   (homun-stage-rows-drag (homun-stage-rows-test--event 'drag-mouse-1 "Beta job" 'done))
   (should (equal "DONE" (plist-get (claude-task-detail-parse (claude-task-detail-show-json 7)) :state)))
   (should-not (member "Beta job #7" (homun-stage-rows-test--labels)))
   (with-current-buffer (homun-stage-buffer-name homun-stage-work-id)
     (goto-char (point-min))
     (search-forward "Items")
     (should-not (search-forward "Beta job" nil t)))))

(ert-deftest homun-stage-rows-keyboard-move-and-done ()
  (homun-stage-rows-test--with
   (with-current-buffer (homun-stage-buffer-name homun-stage-work-id)
     (goto-char (homun-stage-rows-test--pos "Alpha job"))
     (homun-stage-rows-down)
     (should (equal "Alpha job" (plist-get (homun-stage-rows--at) :label)))
     (should (equal '("Beta job #7" "Alpha job" "Gamma job") (homun-stage-rows-test--labels)))
     (homun-stage-rows-up)
     (should (equal '("Alpha job" "Beta job #7" "Gamma job") (homun-stage-rows-test--labels)))
     (homun-stage-rows-done-at-point)
     (should (equal '("Beta job #7" "Gamma job") (homun-stage-rows-test--labels))))))

(ert-deftest homun-stage-rows-click-without-row-is-ignored ()
  (homun-stage-rows-test--with
   (should-not (homun-stage-rows-drag (homun-stage-rows-test--event 'drag-mouse-1 "Alpha job" "Alpha job")))))

(ert-deftest homun-stage-rows-run-detail-pills ()
  (homun-stage-rows-test--with
   (with-temp-buffer
     (claude-run-detail-mode)
     (setq claude-run-detail--agent "a1" claude-run-detail--label "Gamma job")
     (claude-run-detail--redraw)
     (let ((text (buffer-string)))
       (dolist (s '("Back" "Stop" "Retry" "running" "claude-test-9" "Nearly done"))
         (should (string-match-p s text)))))))

(defun homun-stage-rows-test--count (needle)
  (with-current-buffer (homun-stage-buffer-name homun-stage-work-id)
    (how-many (regexp-quote needle) (point-min) (point-max))))

(ert-deftest homun-stage-rows-idle-ticks-touch-nothing ()
  "Syncs and clock ticks with no change: the Items list and the live strip once each,
no render from a tick, no change to the buffer."
  (homun-stage-rows-test--with
   (with-temp-file claude-links-file
     (insert (format "{\"agent\":\"a1\",\"kind\":\"todo\",\"desc\":\"Gamma job\",\"status\":\"wait\",\"transcript\":%S}\n" transcript)))
   (setq claude-links--rows nil)
   (let ((renders 0) (homun-stage-live-visible-function (lambda (_) t)))
     (advice-add 'homun-stage-render :before (lambda (&rest _) (cl-incf renders)) '((name . count)))
     (unwind-protect
         (progn
           (dotimes (_ 5) (homun-stage-work-sync) (homun-stage-rows-redraw))
           (should (= 1 (homun-stage-rows-test--count "Items")))
           (should (= 1 (homun-stage-rows-test--count "stalls 1h")))
           (let ((buf (get-buffer (homun-stage-buffer-name homun-stage-work-id))))
             (homun-stage-live--tick t)
             (let ((tick (buffer-modified-tick buf)) (before renders))
               (dotimes (_ 20) (homun-stage-live--tick t))
               (should (= renders before))
               (should (= tick (buffer-modified-tick buf))))))
       (advice-remove 'homun-stage-render 'count)))))

(ert-deftest homun-stage-rows-each-task-once ()
  "After syncs and ticks, whatever the state, each task id and label shows exactly once."
  (homun-stage-rows-test--with
   (let ((homun-stage-live-visible-function (lambda (_) t)))
     (dolist (state '("running" "wait" "failed" "done"))
       (with-temp-file claude-links-file
         (insert (format "{\"agent\":\"a1\",\"kind\":\"todo\",\"desc\":\"Gamma job\",\"status\":%S,\"transcript\":%S}\n" state transcript)))
       (setq claude-links--rows nil)
       (dotimes (_ 3) (homun-stage-work-sync) (homun-stage-rows-redraw) (homun-stage-live--tick nil))
       (dolist (label '("Alpha job" "Beta job" "Gamma job"))
         (with-current-buffer (homun-stage-buffer-name homun-stage-work-id)
           (goto-char (point-min))
           (search-forward "\nItems")
           ;; below the scene's own text, past the sparkline strip: the Items list only
           (should (= 1 (how-many (regexp-quote label) (point) (point-max))))))))))

(provide 'homun-stage-rows-test)
;;; homun-stage-rows-test.el ends here

(ert-deftest homun-stage-rows-fold-old-done ()
  (homun-stage-rows-test--with
   (let ((rows (cl-loop for i below 7 collect (list :id (format "d%d" i) :label (format "Fin%d" i) :state "done"))))
     (with-temp-buffer
       (cl-letf (((symbol-function 'homun-stage-live-work-refresh) #'ignore)
                 ((symbol-function 'homun-stage-live-prune) #'ignore)
                 ((symbol-function 'homun-stage-live-draw-row)
                  (lambda (r) (prog1 (point) (insert (cadr r))))))
         (homun-stage-rows-insert rows))
       (should (string-match-p "2 earlier" (buffer-string)))
       (should-not (string-match-p "Fin1" (buffer-string)))
       (should (string-match-p "Fin6" (buffer-string)))))))
