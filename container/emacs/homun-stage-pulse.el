;;; homun-stage-pulse.el --- The `pulse' preset: the idle scene, on homun-clock -*- lexical-binding: t -*-

;; Off by default (`homun-stage-pulse-enabled').  Once the user has been idle
;; `homun-stage-pulse-idle-minutes' the scene "pulse" opens on the Stage: three rings breathing,
;; drawn by shape nodes over `t', redrawn by one homun-clock client.  The client ends (the clock
;; pauses) while the scene is hidden; the next idle tick shows it again.  Any input closes it.

;;; Code:

(require 'homun-clock)
(require 'homun-stage-store)

(defvar homun-stage-pulse-enabled nil "Open the pulse scene when the user is idle.")
(defvar homun-stage-pulse-idle-minutes 10 "Minutes of user idleness before it opens.")
(defvar homun-stage-pulse--timer nil)

(defun homun-stage-pulse-scene ()
  "The scene tree: three rings, breathing out of step."
  (cl-flet ((wave (phase) `("sin" ("+" ("*" "t" 1.5) ,phase))))
    `((type . "layer")
      (children
       . ,(cl-loop for k below 3
                   for wave = (wave (* k 2.1))
                   collect `((type . "shape") (kind . "circle") (id . ,(format "ring%d" k))
                             (x . 120) (y . 120) (stroke . "accent")
                             (r (expr "+" 40 ("*" 25 ,wave)))
                             (opacity (expr "+" 0.5 ("*" 0.4 ,wave)))))))))

(defun homun-stage-pulse--shown-p ()
  "Non-nil while a visible window shows the scene."
  (when-let* ((buf (get-buffer (homun-stage-buffer-name "pulse")))
              (win (get-buffer-window buf t)))
    (frame-visible-p (window-frame win))))

(defun homun-stage-pulse--frame (_snap)
  "The clock client: redraw the scene; nil (the clock pauses) once it is gone or
hidden."
  (when-let* ((s (gethash "pulse" homun-stage-scenes))
              ((homun-stage-pulse--shown-p)))
    (homun-stage-render s)
    t))

(defun homun-stage-pulse-stop ()
  "Close the scene and stop its clock client."
  (interactive)
  (remove-hook 'pre-command-hook #'homun-stage-pulse-stop)
  (homun-clock-unregister 'stage-pulse)
  (when (gethash "pulse" homun-stage-scenes) (homun-stage-close "cal" "pulse")))

(defun homun-stage-pulse-start ()
  "Open the scene on the Stage, if it is not open, and run it on the clock."
  (interactive)
  (unless (gethash "pulse" homun-stage-scenes)
    (homun-stage-show "cal" "pulse" "Pulse" (homun-stage-pulse-scene) "ephemeral"))
  (unless noninteractive (homun-stage-display "pulse"))
  (add-hook 'pre-command-hook #'homun-stage-pulse-stop)
  (homun-clock-register 'stage-pulse #'homun-stage-pulse--frame)
  "pulse")

(defun homun-stage-pulse-arm ()
  "Arm or disarm the idle trigger by `homun-stage-pulse-enabled'."
  (when homun-stage-pulse--timer (cancel-timer homun-stage-pulse--timer))
  (setq homun-stage-pulse--timer
        (and homun-stage-pulse-enabled
             (run-with-idle-timer (* 60 homun-stage-pulse-idle-minutes) t #'homun-stage-pulse-start))))

(homun-stage-pulse-arm)
(provide 'homun-stage-pulse)
;;; homun-stage-pulse.el ends here
