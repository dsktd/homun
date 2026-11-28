;;; claude-outbox.el --- The states of a message waiting to be sent -*- lexical-binding: t -*-

;; One state machine for the user's queued messages.  The outbox list in `claude-compose' holds
;; the messages; the transcript draws them.  A message's `:state' changes only through
;; `claude-outbox-move', which refuses a move the table does not list, so no message is ever in
;; a state it cannot have reached.
;;
;;   pending   queued, will be sent
;;   held      queued, but the transcript is focused: nothing is sent until it is left
;;   sending   in flight
;;   sent      accepted by the channel (a transcript later shows it as seen)
;;   failed    refused; retry puts it back to pending, drop cancels it
;;   cancelled taken back by the user (it leaves the outbox)
;;
;; Held is a function of focus alone (`claude-outbox-hold'): pending becomes held while the
;; transcript is focused and held becomes pending when it is not.

;;; Code:

(require 'cl-lib)

(defconst claude-outbox-moves
  '((pending   held sending sent failed cancelled)
    (held      pending sent failed cancelled)
    (sending   pending sent failed)
    (failed    pending cancelled)
    (sent)
    (cancelled))
  "Each state and the states it may move to.")

(defun claude-outbox-move (message state &optional error)
  "Move MESSAGE (a plist with :state) to STATE with ERROR; signal when not allowed.
A move to the state it is in is a no-op."
  (let ((from (plist-get message :state)))
    (unless (or (eq from state) (memq state (cdr (assq from claude-outbox-moves))))
      (error "Message cannot go from %s to %s" from state))
    (plist-put message :state state)
    (plist-put message :error error)))

(defun claude-outbox-focused-p ()
  "Non-nil while the selected window shows a transcript and its frame has focus.
A frame whose focus is unknown (a terminal without focus events) does not count."
  (and (eq t (frame-focus-state))
       (with-current-buffer (window-buffer (selected-window))
         (derived-mode-p 'claude-transcript-mode))))

(defun claude-outbox-hold (messages held)
  "Hold the pending MESSAGES when HELD, release the held ones otherwise.
Return non-nil when a message changed."
  (let (changed)
    (dolist (m messages)
      (let ((state (plist-get m :state)))
        (cond ((and held (eq state 'pending)) (claude-outbox-move m 'held) (setq changed t))
              ((and (not held) (eq state 'held)) (claude-outbox-move m 'pending) (setq changed t)))))
    changed))

(provide 'claude-outbox)
;;; claude-outbox.el ends here
