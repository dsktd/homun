;;; homun-freeze-watch.el --- Log what ran when the daemon stalled -*- lexical-binding: t -*-

;; On in the desktop daemon (cockpit.el enables it at startup); M-x homun-freeze-watch-mode
;; toggles it, M-x homun-freeze-report summarises the log.  A tick every
;; `homun-freeze-watch-period' seconds measures how late it fired.  A gap over
;; `homun-freeze-watch-threshold' appends one line to `homun-freeze-watch-log': the gap, the
;; CPU profiler's heaviest stacks since the previous tick, the GC time spent in it, and the
;; timers and file-notify callbacks that ran across it (each with how long it took, or
;; `:unfinished' while it still runs).  A freeze that never ends logs nothing until it is
;; broken; the line is written by the first tick after it.

;;; Code:

(require 'cl-lib)
(require 'profiler)

(defvar homun-freeze-watch-log (expand-file-name "~/claude/.services/emacs/freeze-gaps.log"))
(defvar homun-freeze-watch-period 0.5 "Seconds between ticks.")
(defvar homun-freeze-watch-threshold 0.5 "Seconds of lateness that count as a gap.")
(defvar homun-freeze-watch-max-bytes 1000000 "The log rotates to LOG.1 above this size.")
(defvar homun-freeze-watch-sample-ns 20000000 "CPU profiler sampling interval.")
(defvar homun-freeze-watch-time-function #'float-time)

(defvar homun-freeze-watch-largest-gap nil
  "The largest gap this session as (TIME . SECONDS), replaced only when beaten.")

(defvar homun-freeze-watch--timer nil)
(defvar homun-freeze-watch--last nil "Time of the previous tick.")
(defvar homun-freeze-watch--gc nil "`gc-elapsed' at the previous tick.")
(defvar homun-freeze-watch--runs nil "Recent (START END KIND NAME), newest first.")
(defvar homun-freeze-watch--own-profiler nil "Non-nil when this mode started the profiler.")
(defvar homun-freeze-watch--lent nil "Non-nil while `profile start' has the profiler.")

(defun homun-freeze-watch--name (fn)
  (let ((s (if (symbolp fn) (symbol-name fn) (prin1-to-string fn))))
    (substring s 0 (min 80 (length s)))))

(defun homun-freeze-watch--record (kind name fn args)
  "Call FN with ARGS, noting its run as KIND NAME."
  (let ((run (list (funcall homun-freeze-watch-time-function) :unfinished kind name)))
    (push run homun-freeze-watch--runs)
    (when (nthcdr 24 homun-freeze-watch--runs) (setcdr (nthcdr 15 homun-freeze-watch--runs) nil))
    (unwind-protect (apply fn args)
      (setf (nth 1 run) (funcall homun-freeze-watch-time-function)))))

(defun homun-freeze-watch--timer-advice (fn timer)
  (homun-freeze-watch--record 'timer (homun-freeze-watch--name (timer--function timer))
                              fn (list timer)))

(defun homun-freeze-watch--notify-advice (fn &rest args)
  (homun-freeze-watch--record 'file-notify (homun-freeze-watch--name (nth 0 (car args)))
                              fn args))

(defun homun-freeze-watch--stacks ()
  "The heaviest stacks the profiler took since the last call, if this mode runs it."
  (when homun-freeze-watch--own-profiler
    (let (rows)
      (ignore-errors
        (maphash (lambda (bt n) (push (cons n bt) rows)) (profiler-cpu-log)))
      (mapcar (lambda (r)
                (cons (car r)
                      (mapcar #'homun-freeze-watch--name
                              (seq-take (seq-remove #'null (append (cdr r) nil)) 12))))
              (seq-take (sort rows (lambda (a b) (> (car a) (car b)))) 5)))))

(defun homun-freeze-watch--entry (now gap)
  (list :at (format-time-string "%FT%T%z" now) :gap (/ (round gap 0.01) 100.0)
        :gc (/ (round (- gc-elapsed (or homun-freeze-watch--gc gc-elapsed)) 0.01) 100.0)
        :runs (cl-loop for (start end kind name) in homun-freeze-watch--runs
                       when (or (eq end :unfinished) (> end (- now gap 1)))
                       collect (list kind name (if (numberp end) (/ (round (- end start) 0.001) 1000.0) end)))
        :stacks (homun-freeze-watch--stacks)))

;;; The one CPU profiler: this mode has it unless it is lent

(defun homun-freeze-watch--claim ()
  "Start the profiler for this mode when it is on, not lent and the profiler is
idle."
  (when (and homun-freeze-watch-mode (not homun-freeze-watch--lent)
             (not homun-freeze-watch--own-profiler) (not (profiler-cpu-running-p)))
    (profiler-cpu-start homun-freeze-watch-sample-ns)
    (setq homun-freeze-watch--own-profiler t)))

(defun homun-freeze-watch-profiler-lend ()
  "Hand the profiler to another measurement; non-nil when it is free for it.
Gaps logged while it is lent have no stacks.
`homun-freeze-watch-profiler-reclaim' ends it."
  (unless homun-freeze-watch--lent
    (when homun-freeze-watch--own-profiler
      (ignore-errors (profiler-cpu-stop))
      (setq homun-freeze-watch--own-profiler nil))
    (unless (profiler-cpu-running-p)
      (setq homun-freeze-watch--lent t))))

(defun homun-freeze-watch-profiler-reclaim ()
  "Take the profiler back after `homun-freeze-watch-profiler-lend'."
  (setq homun-freeze-watch--lent nil)
  (homun-freeze-watch--claim))

;;; The log

(defun homun-freeze-watch--rotate ()
  "Move the log to LOG.1 when it is over `homun-freeze-watch-max-bytes'."
  (let ((size (file-attribute-size (file-attributes homun-freeze-watch-log))))
    (when (and size (> size homun-freeze-watch-max-bytes))
      (rename-file homun-freeze-watch-log (concat homun-freeze-watch-log ".1") t))))

(defun homun-freeze-watch--read ()
  "The logged gaps, oldest first, each a plist with :time (float seconds)."
  (when (file-readable-p homun-freeze-watch-log)
    (with-temp-buffer
      (insert-file-contents homun-freeze-watch-log)
      (let (rows)
        (while (not (eobp))
          (when-let* ((e (ignore-errors (read (current-buffer))))
                      ((listp e))
                      (at (ignore-errors (float-time (date-to-time (plist-get e :at))))))
            (push (plist-put e :time at) rows))
          (skip-chars-forward " \n"))
        (nreverse rows)))))

(defun homun-freeze-watch-count (min-gap seconds)
  "How many logged gaps of at least MIN-GAP seconds fall in the last SECONDS."
  (let ((from (- (float-time) seconds)))
    (cl-count-if (lambda (e) (and (> (plist-get e :time) from) (>= (plist-get e :gap) min-gap)))
                 (homun-freeze-watch--read))))

(defun homun-freeze-watch--top (e n)
  "The N heaviest stacks of gap E as strings."
  (mapcar (lambda (s) (format "%dx %s" (car s) (mapconcat #'identity (seq-take (cdr s) 4) " < ")))
          (seq-take (plist-get e :stacks) n)))

;;;###autoload
(defun homun-freeze-report (&optional n)
  "Show the last N (default 10) gaps: time, length and the top 3 stacks."
  (interactive "P")
  (let* ((rows (last (homun-freeze-watch--read) (prefix-numeric-value (or n 10))))
         (buf (get-buffer-create "*homun-freeze-report*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (null rows)
            (insert "No gaps logged in " homun-freeze-watch-log "\n")
          (dolist (e (reverse rows))
            (insert (format "%s  %.2fs  gc %.2fs\n" (plist-get e :at) (plist-get e :gap) (or (plist-get e :gc) 0)))
            (dolist (s (or (homun-freeze-watch--top e 3) '("no stacks")))
              (insert "    " s "\n"))))
        (goto-char (point-min))
        (special-mode)))
    (if (called-interactively-p 'interactive) (pop-to-buffer buf) buf)))

(defun homun-freeze-watch-tick ()
  "Log a gap when this tick came late; reset the profiler window either way."
  (let* ((now (funcall homun-freeze-watch-time-function))
         (gap (- now (or homun-freeze-watch--last now) homun-freeze-watch-period)))
    (if (> gap homun-freeze-watch-threshold)
        (ignore-errors
          (when (> gap (or (cdr homun-freeze-watch-largest-gap) 0))
            (setq homun-freeze-watch-largest-gap (cons now gap)))
          (let ((line (concat (let ((print-escape-newlines t) (print-length nil) (print-level nil))
                                (prin1-to-string (homun-freeze-watch--entry now gap)))
                              "\n")))
            (homun-freeze-watch--rotate)
            (write-region line nil homun-freeze-watch-log t 'silent)))
      (homun-freeze-watch--stacks))
    ;; A profiler someone else ran and stopped leaves the mode without stacks: take it back
    (homun-freeze-watch--claim)
    (setq homun-freeze-watch--last now homun-freeze-watch--gc gc-elapsed)))

;;;###autoload
(define-minor-mode homun-freeze-watch-mode
  "Log daemon stalls to `homun-freeze-watch-log'."
  :global t :group 'convenience
  (when homun-freeze-watch--timer (cancel-timer homun-freeze-watch--timer))
  (setq homun-freeze-watch--timer nil homun-freeze-watch--last nil homun-freeze-watch--runs nil)
  (advice-remove 'timer-event-handler #'homun-freeze-watch--timer-advice)
  (advice-remove 'file-notify-handle-event #'homun-freeze-watch--notify-advice)
  (when homun-freeze-watch--own-profiler
    (ignore-errors (profiler-cpu-stop))
    (setq homun-freeze-watch--own-profiler nil))
  (when homun-freeze-watch-mode
    (homun-freeze-watch--claim)
    (advice-add 'timer-event-handler :around #'homun-freeze-watch--timer-advice)
    (advice-add 'file-notify-handle-event :around #'homun-freeze-watch--notify-advice)
    (setq homun-freeze-watch--timer
          (run-with-timer homun-freeze-watch-period homun-freeze-watch-period
                          #'homun-freeze-watch-tick))))

(provide 'homun-freeze-watch)
;;; homun-freeze-watch.el ends here
