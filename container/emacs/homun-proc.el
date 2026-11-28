;;; homun-proc.el --- External commands that never block the daemon unbounded -*- lexical-binding: t -*-

;; `homun-proc-async' runs a command from a timer or hook: it returns at once, skips a call
;; while the previous one of the same KEY still runs, and calls DONE with (STATUS OUTPUT)
;; from the sentinel.  `homun-proc-sync' is for a short call a user waits for: it gives the
;; command a timeout.  A call over `homun-proc-slow' seconds is logged, named, to the
;; freeze log.

;;; Code:

(require 'cl-lib)

(defvar homun-freeze-watch-log)

(defvar homun-proc-slow 2.0 "Seconds after which a call is logged to the freeze log.")
(defvar homun-proc-timeout 10.0 "Default seconds `homun-proc-sync' waits.")
(defvar homun-proc--running (make-hash-table :test #'equal) "KEY -> live process.")
(defvar homun-proc-breaker 60.0 "Seconds `homun-proc-sync' skips a call whose last one timed out.")
(defvar homun-proc--tripped (make-hash-table :test #'equal) "KEY -> time until which it is skipped.")

(defun homun-proc--log (key seconds &rest more)
  "Note that the call KEY took SECONDS; MORE is added to the record.
An async call's SECONDS run to its sentinel, so they include any stall of the
daemon itself (`:async t' says so): it never blocked anything."
  (when (> seconds homun-proc-slow)
    (ignore-errors
      (make-directory (file-name-directory homun-freeze-watch-log) t)
      (write-region (concat (prin1-to-string
                             (append (list :at (format-time-string "%FT%T%z") :external key
                                           :took (/ (round seconds 0.01) 100.0))
                                     more))
                            "\n")
                    nil homun-freeze-watch-log t 'silent))))

(defun homun-proc--start (program args stdin sentinel)
  "Start PROGRAM with ARGS, STDIN sent to it; SENTINEL gets the process.  Nil when
it cannot start."
  (condition-case nil
      (let ((proc (make-process :name (format "homun-proc %s" program)
                                :buffer (generate-new-buffer " *homun-proc*")
                                :command (cons program args) :connection-type 'pipe
                                :noquery t :stderr nil :sentinel sentinel)))
        (when stdin (process-send-string proc stdin))
        (process-send-eof proc)
        proc)
    (file-error nil)))

(defun homun-proc--take (proc)
  "The output of PROC; kills its buffer."
  (let ((buf (process-buffer proc)))
    (prog1 (and (buffer-live-p buf) (with-current-buffer buf (buffer-string)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(defun homun-proc-async (key program args done &optional stdin)
  "Run PROGRAM with ARGS without waiting; return the process, or nil when skipped.
Skipped while the process of the same KEY runs.  DONE is called with STATUS and
OUTPUT."
  (let ((old (gethash key homun-proc--running)))
    (unless (and old (process-live-p old))
      (let* ((t0 (float-time))
             (proc (homun-proc--start
                    program args stdin
                    (lambda (p _event)
                      (unless (process-live-p p)
                        (remhash key homun-proc--running)
                        (homun-proc--log key (- (float-time) t0) :async t)
                        (let ((out (homun-proc--take p)))
                          (when done (funcall done (process-exit-status p) out))))))))
        (when proc (puthash key proc homun-proc--running))
        proc))))

(defun homun-proc-sync (program args &optional stdin timeout)
  "Run PROGRAM with ARGS and wait at most TIMEOUT seconds; return (STATUS .
OUTPUT).
STATUS is the exit code, or nil when it did not start, was killed at the timeout
or was skipped: after a timeout the same call (PROGRAM and first argument) is
skipped for `homun-proc-breaker' seconds, logged once.  The wait runs no timers,
so no other caller nests its own wait inside this one."
  (let* ((t0 (float-time))
         (key (format "%s %s" program (car args)))
         (until (gethash key homun-proc--tripped)))
    (if (and until (< t0 until)) (cons nil "")
      (remhash key homun-proc--tripped)
      (let ((proc (homun-proc--start program args stdin #'ignore))
            (limit (+ t0 (or timeout homun-proc-timeout))))
        (if (null proc) (cons nil "")
          (while (and (process-live-p proc) (< (float-time) limit))
            (accept-process-output proc 0.05 nil 1))
          (let ((live (process-live-p proc)))
            (when live
              (delete-process proc)
              (puthash key (+ (float-time) homun-proc-breaker) homun-proc--tripped))
            (apply #'homun-proc--log key (- (float-time) t0)
                   (and live (list :timeout t :skipped-for homun-proc-breaker)))
            (cons (and (not live) (process-exit-status proc)) (homun-proc--take proc))))))))

(provide 'homun-proc)
;;; homun-proc.el ends here
