;;; claude-agent-view.el --- Read a subagent in the transcript window -*- lexical-binding: t -*-

;; The view is in one of two states, kept as a frame parameter: `main' (the transcript window shows
;; what it showed) or (viewing FILE) (it shows the subagent transcript FILE, and the compose box is
;; hidden unless FILE belongs to a session that takes messages).  `claude-agent-view-open' enters
;; it, `claude-agent-view-leave' restores the buffer that was there and the box.

(require 'cl-lib)
(require 'seq)
(require 'homun-layout)

(declare-function claude-transcript-buffer "claude-transcript")
(declare-function claude-compose--route-for-file "claude-compose")
(declare-function claude-compose-route-buffer "claude-compose")
(declare-function claude-compose--show "claude-compose")
(declare-function claude-compose--pair "claude-compose")
(declare-function claude-compose--visible-routes "claude-compose")
(declare-function homun-stage-agent-open "homun-stage-agent")

(defconst claude-agent-view--param 'claude-agent-view
  "Frame parameter holding (WINDOW PREVIOUS-BUFFER FILE) while an agent is viewed.")

(defun claude-agent-view--saved (&optional frame)
  (frame-parameter frame claude-agent-view--param))

(defun claude-agent-view-state (&optional frame)
  "`main', or (viewing FILE) while the transcript window of FRAME shows a subagent."
  (if-let* ((saved (claude-agent-view--saved frame))
            ((window-live-p (car saved))))
      (list 'viewing (nth 2 saved))
    'main))

(defun claude-agent-view--window ()
  (seq-find (lambda (w)
              (with-current-buffer (window-buffer w)
                (derived-mode-p 'claude-transcript-mode)))
            (window-list nil 'no-minibuf)))

(defun claude-agent-view-open (file)
  "Show the subagent transcript FILE in the transcript window, in place of the
session's; hide the compose box unless FILE's session takes messages."
  (require 'claude-transcript)
  (require 'claude-compose)
  (let ((window (or (car (claude-agent-view--saved)) (claude-agent-view--window))))
    (if (not (window-live-p window))
        (progn (require 'homun-stage-agent) (homun-stage-agent-open file))
      (let ((saved (claude-agent-view--saved)))
        (set-frame-parameter nil claude-agent-view--param
                             (list window (if (and saved (window-live-p (car saved)))
                                              (nth 1 saved)
                                            (window-buffer window))
                                   file)))
      (homun-layout-show (claude-transcript-buffer file) window)
      (if-let* ((route (claude-compose--route-for-file file)))
          (claude-compose--show route)
        (claude-compose--pair))
      (select-window window))))

(defun claude-agent-view-leave ()
  "Back to the main transcript: restore the buffer the window showed, and its box."
  (interactive)
  (when-let* ((saved (claude-agent-view--saved))
              ((window-live-p (car saved))))
    (set-frame-parameter nil claude-agent-view--param nil)
    (let ((buffer (nth 1 saved)))
      (when (buffer-live-p buffer)
        (homun-layout-show buffer (car saved))
        (claude-compose--pair)
        (when-let* ((file (buffer-local-value 'claude-transcript--file buffer))
                    (route (claude-compose--route-for-file file))
                    ((not (assoc (claude-compose-route-buffer route)
                                 (claude-compose--visible-routes (selected-frame))))))
          (save-selected-window (claude-compose--show route)))))
    (select-window (car saved)))
  (set-frame-parameter nil claude-agent-view--param nil))

(defun claude-agent-view-quit ()
  "Leave the subagent view when in one, else bury the buffer."
  (interactive)
  (if (eq (claude-agent-view-state) 'main) (bury-buffer) (claude-agent-view-leave)))

(provide 'claude-agent-view)
;;; claude-agent-view.el ends here
