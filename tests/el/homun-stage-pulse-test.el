;;; homun-stage-pulse-test.el --- The pulse preset runs on homun-clock and pauses when hidden -*- lexical-binding: t -*-

(require 'ert)
(require 'homun-stage-pulse)

(defmacro homun-stage-pulse-test--with (&rest body)
  `(let* ((homun-stage-dir (file-name-as-directory (make-temp-file "stage" t)))
          (homun-stage-scenes (make-hash-table :test #'equal))
          (homun-clock--clients nil) (homun-clock--periods nil) (homun-clock--timer nil)
          (homun-clock--wanted nil)
          (homun-clock-focused-function (lambda () t)))
     (unwind-protect (progn ,@body)
       (homun-clock--stop)
       (dolist (b (buffer-list))
         (when (string-prefix-p "*stage " (buffer-name b)) (kill-buffer b)))
       (delete-directory homun-stage-dir t))))

(ert-deftest homun-stage-pulse-scene-is-valid ()
  (should (homun-stage--check-tree (homun-stage-pulse-scene))))

(ert-deftest homun-stage-pulse-runs-on-the-clock ()
  (homun-stage-pulse-test--with
   (homun-stage-pulse-start)
   (should (gethash "pulse" homun-stage-scenes))
   (should (assq 'stage-pulse homun-clock--clients))
   (should (= 1 (homun-clock-timers)))
   (homun-stage-pulse-stop)
   (should-not (gethash "pulse" homun-stage-scenes))
   (should-not homun-clock--clients)))

(ert-deftest homun-stage-pulse-pauses-when-hidden ()
  (homun-stage-pulse-test--with
   (homun-stage-pulse-start)
   (cl-letf (((symbol-function 'homun-stage-pulse--shown-p) (lambda () nil)))
     (homun-clock-tick))
   (should (= 0 (homun-clock-timers)))
   (cl-letf (((symbol-function 'homun-stage-pulse--shown-p) (lambda () t)))
     (should (homun-stage-pulse--frame nil)))
   (homun-stage-pulse-stop)))
