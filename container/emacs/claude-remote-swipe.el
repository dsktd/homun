;;; claude-remote-swipe.el --- Horizontal swipes on the phone's touch screen -*- lexical-binding: t -*-

;; Android Emacs turns a touch into `touchscreen-begin', `touchscreen-update' and `touchscreen-end'
;; events and, when the finger did not drag, into a tap.  This watches the same events from an advice
;; of `touch-screen-handle-touch' and, when one finger lifts far to the side and not far up or down,
;; calls `claude-remote-swipe-function' with `left' or `right' and the window.  The events go on to
;; touch-screen.el unchanged, so taps, scrolling and pinching work as before.

(require 'subr-x)

(defcustom claude-remote-swipe-fraction 0.25
  "How far a swipe goes, as a fraction of the window's width."
  :type 'float :group 'claude)

(defcustom claude-remote-swipe-steepness 2.0
  "A swipe goes this many times further across than up or down."
  :type 'float :group 'claude)

(defvar claude-remote-swipe-function nil
  "Called with `left' or `right' and the window the finger went down in.")

(defvar claude-remote-swipe-active-function nil
  "Called with a window at touch-down; swipes are followed only when it returns non-nil.
Nil means every window.")

(defvar claude-remote-swipe--start nil
  "The finger being followed: (ID WINDOW X Y), or nil.  A second finger ends it.")

(defun claude-remote-swipe--xy (position)
  "The pixel (X . Y) of the posn POSITION in its window, or nil."
  (let ((xy (ignore-errors (posn-x-y position))))
    (and (consp xy) (numberp (car xy)) (numberp (cdr xy)) xy)))

(defun claude-remote-swipe-direction (dx dy width)
  "`left', `right' or nil for a finger that moved DX and DY pixels in a window WIDTH wide."
  (and (> width 0)
       (>= (abs dx) (* claude-remote-swipe-fraction width))
       (>= (abs dx) (* claude-remote-swipe-steepness (abs dy)))
       (if (< dx 0) 'left 'right)))

(defun claude-remote-swipe-feed (event)
  "Follow the touch EVENT; at the lift of a swipe call `claude-remote-swipe-function'.
Every kind of event is handled: the others are not ours and are left alone."
  (pcase event
    (`(touchscreen-begin (,id . ,position))
     (let ((window (posn-window position)) (xy (claude-remote-swipe--xy position)))
       ;; a second finger is a pinch, not a swipe
       (setq claude-remote-swipe--start
             (and (null claude-remote-swipe--start) (windowp window) xy
                  (or (null claude-remote-swipe-active-function)
                      (funcall claude-remote-swipe-active-function window))
                  (list id window (car xy) (cdr xy))))))
    (`(touchscreen-update ,points)
     (when (and claude-remote-swipe--start (length> points 1))
       (setq claude-remote-swipe--start nil)))
    (`(touchscreen-end (,id . ,position) . ,rest)
     (when-let* ((start claude-remote-swipe--start)
                 ((eql id (nth 0 start))))
       (setq claude-remote-swipe--start nil)
       ;; a cancelled touch (the system took the finger) is no swipe
       (unless (car rest)
       (let* ((window (nth 1 start)) (xy (claude-remote-swipe--xy position))
              (direction (and xy (window-live-p window)
                              (claude-remote-swipe-direction (- (car xy) (nth 2 start)) (- (cdr xy) (nth 3 start))
                                                             (window-pixel-width window)))))
         (when (and direction claude-remote-swipe-function)
           (let ((fn claude-remote-swipe-function))
             ;; after the key translation that is running now
             (run-at-time 0 nil (lambda () (with-demoted-errors "swipe: %S" (funcall fn direction window))))))))))
    (_ nil)))

(defun claude-remote-swipe--advice (event &rest _)
  "Advice for `touch-screen-handle-touch': let `claude-remote-swipe-feed' see EVENT.
Only watches: it never changes the event, the selection or the mark, and returns nil."
  (condition-case err (claude-remote-swipe-feed event)
    (error (message "swipe: %S" err)))
  nil)

(defun claude-remote-swipe-setup ()
  "Watch the touch events for swipes."
  (advice-add 'touch-screen-handle-touch :before #'claude-remote-swipe--advice))

(provide 'claude-remote-swipe)
;;; claude-remote-swipe.el ends here
