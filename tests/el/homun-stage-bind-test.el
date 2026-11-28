;;; homun-stage-bind-test.el --- ERT for live bindings and stale alarms -*- lexical-binding: t -*-

(require 'ert)
(require 'homun-stage-bind)

(defvar homun-stage-bind-test--now 100.0)

(defmacro homun-stage-bind-test--with (&rest body)
  `(let* ((homun-stage-dir (file-name-as-directory (make-temp-file "stage" t)))
          (homun-stage-scenes (make-hash-table :test #'equal))
          (homun-stage-bindings (make-hash-table :test #'equal))
          (homun-stage-bind--times (make-hash-table :test #'equal))
          (homun-stage-bind--born (make-hash-table :test #'equal))
          (homun-stage-bind--dirty nil) (homun-stage-bind--alarmed nil) (homun-stage-stale nil)
          (homun-stage-bind--no-timer t)
          (homun-stage-bind-test--now 100.0) (alarms nil)
          (homun-stage-bind-time-function (lambda () homun-stage-bind-test--now))
          (homun-stage-bind-alarm-function (lambda (m) (push m alarms)))
          (homun-clock--clients nil))
     (cl-letf (((symbol-function 'homun-clock-dirty) #'ignore))
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (string-prefix-p "*stage " (buffer-name b)) (kill-buffer b)))
         (delete-directory homun-stage-dir t)))))

(defconst homun-stage-bind-test--root
  '((type . "meter") (id . "m") (value . ((bind . "state.job.pct"))) (label . "job")))

(ert-deftest homun-stage-bind-publish-updates-in-one-frame ()
  (homun-stage-bind-test--with
   (homun-stage-show "manager" "job" "Job" homun-stage-bind-test--root nil 1000)
   (homun-stage-publish "state.job.pct" 0.5)
   (funcall (cdr (assoc 'stage-bind homun-clock--clients)) nil)
   (should (string-match-p "50%" (with-current-buffer "*stage job*" (buffer-string))))
   (homun-stage-publish "state.job.pct" 0.9)
   (should (string-match-p "50%" (with-current-buffer "*stage job*" (buffer-string))))
   (funcall (cdr (assoc 'stage-bind homun-clock--clients)) nil)
   (should (string-match-p "90%" (with-current-buffer "*stage job*" (buffer-string))))))

(ert-deftest homun-stage-bind-silence-alarms-once-then-recovers ()
  (homun-stage-bind-test--with
   (homun-stage-show "manager" "job" "Job" homun-stage-bind-test--root nil 1000)
   (homun-stage-publish "state.job.pct" 0.5)
   (setq homun-stage-bind-test--now 100.5) (homun-stage-bind-check)
   (should-not alarms)
   (setq homun-stage-bind-test--now 102.0) (homun-stage-bind-check) (homun-stage-bind-check)
   (should (= 1 (length alarms)))
   (should (string-match-p "job" (car alarms)))
   (should (member "state.job.pct" homun-stage-stale))
   (should (eq 'homun-stage-stale
               (get-text-property 0 'face (homun-stage-text homun-stage-bind-test--root))))
   (homun-stage-publish "state.job.pct" 0.6)
   (should-not homun-stage-stale)))

(ert-deftest homun-stage-bind-bus-message-publishes ()
  (homun-stage-bind-test--with
   (homun-stage-bind--message '(:alarm "state.job.pct" :msg "0.25"))
   (should (= 0.25 (gethash "state.job.pct" homun-stage-bindings)))))
