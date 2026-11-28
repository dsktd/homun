;;; homun-proc-test.el --- ERT for homun-proc -*- lexical-binding: t -*-
(require 'ert)
(require 'homun-proc)
(require 'homun-freeze-watch)

(defun homun-proc-test--fake (sleep)
  "A fake homund that sleeps SLEEP seconds, then prints ok."
  (let ((f (make-temp-file "homund" nil ".sh")))
    (write-region (format "#!/bin/sh\nsleep %s\necho ok\n" sleep) nil f)
    (set-file-modes f #o755)
    f))

(ert-deftest homun-proc-slow-command-does-not-block-the-tick ()
  (let* ((fake (homun-proc-test--fake 5)) (homun-proc--running (make-hash-table :test #'equal))
         (t0 (float-time)) proc)
    (unwind-protect
        (progn (setq proc (homun-proc-async "k" fake '("presence") #'ignore))
               (should proc)
               (should (< (- (float-time) t0) 1.0))
               (should (process-live-p proc)))
      (when proc (delete-process proc))
      (delete-file fake))))

(ert-deftest homun-proc-overlapping-ticks-are-skipped ()
  (let* ((fake (homun-proc-test--fake 5)) (homun-proc--running (make-hash-table :test #'equal))
         (first (homun-proc-async "k" fake nil #'ignore)))
    (unwind-protect
        (progn (should first)
               (should-not (homun-proc-async "k" fake nil #'ignore))
               (should (homun-proc-async "other" "true" nil #'ignore)))
      (delete-process first)
      (delete-file fake))))

(ert-deftest homun-proc-async-runs-done-and-frees-the-key ()
  (let* ((homun-proc--running (make-hash-table :test #'equal)) got)
    (homun-proc-async "k" "echo" '("hi") (lambda (s o) (setq got (cons s o))))
    (with-timeout (5 (ert-fail "no sentinel"))
      (while (not got) (accept-process-output nil 0.05)))
    (should (equal got '(0 . "hi\n")))
    (should (homun-proc-async "k" "true" nil nil))))

(ert-deftest homun-proc-sync-times-out-and-logs-slow-calls ()
  (let* ((fake (homun-proc-test--fake 5)) (log (make-temp-file "gaps"))
         (homun-freeze-watch-log log) (homun-proc-slow 0.1) (t0 (float-time)))
    (unwind-protect
        (progn (should-not (car (homun-proc-sync fake nil nil 0.5)))
               (should (< (- (float-time) t0) 2.0))
               (should (string-match-p ":external" (with-temp-buffer (insert-file-contents log) (buffer-string))))
               (should (equal '(0 . "ok\n") (homun-proc-sync (homun-proc-test--fake 0) nil))))
      (delete-file fake) (delete-file log))))

(ert-deftest homun-proc-sync-skips-a-call-that-timed-out ()
  (let* ((fake (homun-proc-test--fake 5)) (log (make-temp-file "gaps"))
         (homun-freeze-watch-log log) (homun-proc-slow 0.1)
         (homun-proc--tripped (make-hash-table :test #'equal)) (t0 nil))
    (unwind-protect
        (progn (should-not (car (homun-proc-sync fake '("x") nil 0.3)))
               (setq t0 (float-time))
               (should (equal '(nil . "") (homun-proc-sync fake '("x") nil 0.3)))
               (should (< (- (float-time) t0) 0.1))
               (let ((text (with-temp-buffer (insert-file-contents log) (buffer-string))))
                 (should (= 1 (cl-count ?\n text)))
                 (should (string-match-p ":timeout t" text))))
      (delete-file fake) (delete-file log))))

(ert-deftest homun-proc-sync-runs-no-timers-while-it-waits ()
  ;; A timer run inside the wait could start its own sync call there: waits nest and add up.
  (let* ((fake (homun-proc-test--fake 0.5)) ran
         (timer (run-at-time 0.05 nil (lambda () (setq ran t)))))
    (unwind-protect
        (progn (should (eql 0 (car (homun-proc-sync fake nil))))
               (should-not ran))
      (cancel-timer timer) (delete-file fake))))
