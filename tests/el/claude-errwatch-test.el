;;; claude-errwatch-test.el --- ERT for the cockpit's error watch -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-errwatch-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'claude-errwatch)

(defvar claude-errwatch-test--sent nil)
(defvar claude-errwatch-test--alarms nil)

(defmacro claude-errwatch-test--box (&rest body)
  `(let* ((dir (make-temp-file "errwatch" t))
          (claude-errwatch-file (expand-file-name "errors.jsonl" dir))
          (claude-errwatch--signatures (make-hash-table :test #'equal))
          (claude-errwatch--timer-errors (make-hash-table :test #'eq :weakness 'key))
          (claude-errwatch--times nil) (claude-errwatch--sends nil)
          (claude-errwatch--last-load nil) (claude-errwatch--rev "test")
          (claude-errwatch--on t)
          (claude-errwatch-test--sent nil) (claude-errwatch-test--alarms nil)
          (claude-errwatch-send-function (lambda (text) (push text claude-errwatch-test--sent)))
          (claude-errwatch-alarm-function (lambda (text) (push text claude-errwatch-test--alarms))))
     (unwind-protect (progn ,@body) (delete-directory dir t))))

(defun claude-errwatch-test--run-timer (fn)
  "Run FN as a timer through the watch, as `timer-event-handler' would."
  (let ((timer (timer-create)))
    (timer-set-function timer fn)
    (claude-errwatch--timer (lambda (tm) (ignore-errors (funcall (timer--function tm)))) timer)
    timer))

(ert-deftest claude-errwatch-captures-a-timer-error-with-frames ()
  (claude-errwatch-test--box
   (claude-errwatch-test--run-timer (lambda () (car 1)))
   (let ((row (aref (claude-errwatch-list) 0)))
     (should (equal (alist-get 'kind row) "timer"))
     (should (equal (alist-get 'error row) "wrong-type-argument"))
     (should (equal (alist-get 'handled row) "sent")))
   (should (= 1 (length claude-errwatch-test--sent)))
   (should (string-match-p "frames:" (car claude-errwatch-test--sent)))
   (should (file-exists-p claude-errwatch-file))))

(ert-deftest claude-errwatch-one-signature-per-shape ()
  (claude-errwatch-test--box
   ;; two different closures of one arity, two arg counts: one signature
   (dotimes (i 5)
     (let ((f (let ((x i)) (lambda (a) (+ a x)))))
       (claude-errwatch-record "timer" "homun-x" (list 'wrong-number-of-arguments f i))))
   (should (= 1 (hash-table-count claude-errwatch--signatures)))
   (should (= 5 (alist-get 'count (aref (claude-errwatch-list) 0))))
   (should (= 1 (length claude-errwatch-test--sent)))
   (should (string-match-p "#\\[1-1\\]" (car claude-errwatch-test--sent)))))

(ert-deftest claude-errwatch-warnings-are-counted-not-sent ()
  (claude-errwatch-test--box
   (claude-errwatch-record "warning" "bytecomp" "docstring wider than 80 characters")
   (should (null claude-errwatch-test--sent))
   (should (= 1 (claude-errwatch-count-1h)))))

(ert-deftest claude-errwatch-stale-reload-repairs-once ()
  (claude-errwatch-test--box
   (let* ((file (expand-file-name "claude-errwatch-stale.el" dir))
          (claude-errwatch-homun-dir (file-name-as-directory dir)))
     (with-temp-file file
       (insert ";;; -*- lexical-binding: t -*-\n(defun claude-errwatch-stale-fn (a b) (+ a b))\n(provide 'claude-errwatch-stale)\n"))
     (load file nil t t)
     (setq claude-errwatch--last-load (float-time))
     (let ((data (list 'wrong-number-of-arguments 'claude-errwatch-stale-fn 1)))
       (claude-errwatch-record "timer" "claude-errwatch-stale-fn" data)
       (should (equal (alist-get 'handled (aref (claude-errwatch-list) 0)) "reloading"))
       (should (null claude-errwatch-test--sent))
       ;; the repair runs from a zero timer
       (with-temp-file file (insert ";;; -*- lexical-binding: t -*-\n(defun claude-errwatch-stale-fn (a) a)\n"))
       (claude-errwatch--repair (car (hash-table-keys claude-errwatch--signatures))
                                (car (hash-table-values claude-errwatch--signatures)))
       (should (= 1 (claude-errwatch-stale-fn 1)))
       (should (equal (alist-get 'handled (aref (claude-errwatch-list) 0)) "reloaded"))
       ;; back again: the repair failed, the manager hears it once
       (claude-errwatch-record "timer" "claude-errwatch-stale-fn" data)
       (claude-errwatch-record "timer" "claude-errwatch-stale-fn" data)
       (should (= 1 (length claude-errwatch-test--alarms)))
       (should (= 1 (claude-errwatch-failed-count)))))))

(ert-deftest claude-errwatch-no-stale-repair-without-a-load ()
  (claude-errwatch-test--box
   (claude-errwatch-record "timer" "car" (list 'void-function 'nope))
   (should (equal (alist-get 'handled (aref (claude-errwatch-list) 0)) "sent"))))

(ert-deftest claude-errwatch-cancels-a-runaway-timer ()
  (claude-errwatch-test--box
   (let* ((claude-errwatch-runaway-per-minute 3)
          (timer (run-at-time 3600 60 (lambda () (car 1)))))
     (unwind-protect
         (progn
           (dotimes (_ 4)
             (claude-errwatch--timer (lambda (tm) (ignore-errors (funcall (timer--function tm)))) timer))
           (should-not (memq timer timer-list))
           (should (seq-find (lambda (r) (equal (alist-get 'kind r) "timer-cancelled"))
                             (claude-errwatch-list))))
       (cancel-timer timer)))))

;;; claude-errwatch-test.el ends here

(ert-deftest claude-errwatch-counts-a-handled-failure-without-sending ()
  (claude-errwatch-test--box
   (claude-errwatch-record "handled" "claude-browse-url" '(portal-failed "No connection to bus"))
   (should (= (claude-errwatch-count-1h) 1))
   (should-not claude-errwatch-test--sent)))
