;;; homun-clock.el --- One timer for every animation -*- lexical-binding: t -*-

;; Clients register a tick function.  A tick function is called with (SNAP) once per frame
;; and returns non-nil while it still animates; when every client returns nil the timer is
;; cancelled, so an idle clock runs no timer.  `homun-clock-dirty' wakes it for one more frame.
;;
;; A frame over `homun-clock-budget' degrades in steps: halve the fps, then pass SNAP = t so
;; tweens jump to their end state, then run `homun-clock-slow-hook' (stage.slow).  Fast frames
;; step back up.  The clock pauses while the Stage window is hidden or the frame has been
;; unfocused for more than `homun-clock-unfocus-limit' seconds.

;;; Code:

(require 'cl-lib)

(defvar homun-clock-max-fps 30 "Frame rate while anything animates.")
(defvar homun-clock-budget 0.008 "Seconds one frame may take.")
(defvar homun-clock-unfocus-limit 30 "Seconds of unfocus after which the clock pauses.")
(defvar homun-clock-time-function #'float-time "Returns the current time in seconds.")
(defvar homun-clock-visible-function (lambda () t) "Non-nil while the Stage window is visible.")
(defvar homun-clock-focused-function
  (lambda () (cl-some (lambda (f) (frame-focus-state f)) (frame-list)))
  "Non-nil while any frame has focus.")
(defvar homun-clock-slow-hook nil "Run with the frame time when degradation reaches its last step.")

(defvar homun-clock--clients nil "Alist of (ID . FUNCTION).")
(defvar homun-clock--periods nil "Alist of (ID . SECONDS): the slowest a client wants to be called.")
(defvar homun-clock--timer nil)
(defvar homun-clock--level 0 "0 full fps, 1 half fps, 2 snapping, 3 slow reported.")
(defvar homun-clock--fast 0 "Consecutive frames well inside the budget.")
(defvar homun-clock--unfocused-since nil)
(defvar homun-clock--wanted nil "Non-nil when a client is active or dirty.")

(defun homun-clock-timers ()
  "The number of timers the clock runs (0 or 1)."
  (if homun-clock--timer 1 0))

(defun homun-clock-fps ()
  "The current frame rate, after degradation."
  (if (>= homun-clock--level 1) (/ homun-clock-max-fps 2.0) (float homun-clock-max-fps)))

(defun homun-clock--paused-p ()
  "Non-nil when the visibility or focus rules pause the clock."
  (let ((now (funcall homun-clock-time-function)))
    (if (funcall homun-clock-focused-function)
        (setq homun-clock--unfocused-since nil)
      (unless homun-clock--unfocused-since (setq homun-clock--unfocused-since now)))
    (or (not (funcall homun-clock-visible-function))
        (and homun-clock--unfocused-since
             (> (- now homun-clock--unfocused-since) homun-clock-unfocus-limit)))))

(defun homun-clock--stop ()
  "Cancel the timer."
  (when homun-clock--timer (cancel-timer homun-clock--timer))
  (setq homun-clock--timer nil))

(defun homun-clock--period ()
  "Seconds between frames: one frame at the current fps, or the shortest client
period if longer.
A client without a period wants every frame."
  (max (/ 1.0 (homun-clock-fps))
       (if (and homun-clock--periods (= (length homun-clock--periods) (length homun-clock--clients)))
           (apply #'min (mapcar #'cdr homun-clock--periods))
         0)))

(defun homun-clock--start ()
  "Start the timer at the current period unless one runs."
  (unless homun-clock--timer
    (let ((period (homun-clock--period)))
      (setq homun-clock--timer (run-at-time period period #'homun-clock-tick)))))

(defun homun-clock--restart ()
  "Rearm the timer after the fps changed."
  (homun-clock--stop)
  (homun-clock--start))

(defun homun-clock--degrade (took)
  "Adjust the degradation level after a frame that took TOOK seconds."
  (cond
   ((> took homun-clock-budget)
    (setq homun-clock--fast 0)
    (when (< homun-clock--level 3)
      (cl-incf homun-clock--level)
      (when (= homun-clock--level 1) (homun-clock--restart))
      (when (= homun-clock--level 3) (run-hook-with-args 'homun-clock-slow-hook took))))
   ((< took (/ homun-clock-budget 2))
    (when (and (> homun-clock--level 0) (>= (cl-incf homun-clock--fast) 30))
      (setq homun-clock--fast 0)
      (cl-decf homun-clock--level)
      (when (= homun-clock--level 0) (homun-clock--restart))))))

(defun homun-clock-tick ()
  "Run one frame: call every client, degrade on overrun, stop when nobody animates."
  (if (homun-clock--paused-p)
      (homun-clock--stop)
    (let ((start (funcall homun-clock-time-function)) (active nil))
      (setq homun-clock--wanted nil)
      (dolist (c (copy-sequence homun-clock--clients))
        (when (funcall (cdr c) (>= homun-clock--level 2)) (setq active t)))
      (homun-clock--degrade (- (funcall homun-clock-time-function) start))
      (unless (or active homun-clock--wanted) (homun-clock--stop)))))

(defun homun-clock-register (id fn &optional period)
  "Register FN under ID (replacing an older one).  FN takes SNAP and returns
non-nil to go on.
PERIOD, in seconds, says FN needs no frames faster than that: while every client
has one, the timer ticks no faster than the shortest."
  (setf (alist-get id homun-clock--clients nil nil #'equal) fn)
  (setf (alist-get id homun-clock--periods nil t #'equal) period)
  (homun-clock--stop)
  (homun-clock-dirty id))

(defun homun-clock-unregister (id)
  "Remove the client ID."
  (setq homun-clock--clients (assoc-delete-all id homun-clock--clients #'equal)
        homun-clock--periods (assoc-delete-all id homun-clock--periods #'equal)))

(defun homun-clock-dirty (&optional _id)
  "Ask for another frame; start the timer when it is stopped and the clock may run."
  (setq homun-clock--wanted t)
  (when (and homun-clock--clients (not (homun-clock--paused-p)))
    (homun-clock--start)))

(provide 'homun-clock)
;;; homun-clock.el ends here
