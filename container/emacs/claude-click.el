;;; claude-click.el --- Click a stage tab from the API, fail closed -*- lexical-binding: t -*-

;;; Commentary:

;; `claude-click' presses what a mouse-1 press would at a place in a buffer of the
;; stage region (a scene, a page, todos, questions, doctor).  It refuses anything
;; that decides something: a button with a friction tier (:confirm hold or
;; drag), a card or prompt of approval, a place whose text says approve, deny,
;; allow or permission, and any buffer outside the stage region.  A refusal is an
;; error; nothing is pressed.

;;; Code:

(require 'homun-layout)
(require 'cl-lib)
(require 'subr-x)
(require 'homun-stage-store)

(defconst claude-click-deny-regexp
  (rx (or "approve" "deny" "allow" "permission" "decline" "reject" "grant"))
  "Text near the place that makes a click refuse.")

(defun claude-click--allowed-p (buffer)
  "Non-nil when BUFFER is a tab of the stage region."
  (memq buffer (append (homun-stage-tab-buffers) (homun-stage-pinned-buffers))))

(defun claude-click--place (label position)
  "The position of LABEL (first match) or POSITION in the current buffer."
  (cond (position (unless (<= (point-min) position (point-max)) (user-error "Position outside the buffer"))
                  position)
        (label (save-excursion
                 (goto-char (point-min))
                 (if (search-forward label nil t) (match-beginning 0)
                   (user-error "No %s in the buffer" label))))
        (t (user-error "Give a label or a position"))))

(defun claude-click--guard (pos)
  "Signal a `user-error' when a click at POS must not happen."
  (let* ((segment (and (fboundp 'widgetry-buttons-segment-at)
                       (ignore-errors (widgetry-buttons-segment-at))))
         (widget (or segment (widget-at pos))))
    (when (get-text-property pos 'claude-transcript-focus-blockers)
      (user-error "Refused: what blocks the agent answers only Cal's own clicks"))
    (when (and widget (widget-get widget :confirm))
      (user-error "Refused: a hold or drag button"))
    (when (and (get-char-property pos 'keymap) (string-match-p "widgetry"
                                                              (format "%S" (get-char-property pos 'keymap)))
               (not widget))
      (user-error "Refused: a widget that cannot be told"))
    (when (string-match-p claude-click-deny-regexp
                          (downcase (buffer-substring-no-properties
                                     (line-beginning-position) (line-end-position))))
      (user-error "Refused: approve, deny or permission text on the line"))))

(defun claude-click (buffer label position)
  "Click in BUFFER (a name) at LABEL's first match or POSITION; return what ran."
  (let ((buf (or (get-buffer buffer) (user-error "No buffer %s" buffer))))
    (unless (claude-click--allowed-p buf)
      (user-error "Refused: %s is not a tab of the stage region" buffer))
    (when (equal buf (get-buffer (homun-stage-buffer-name "approve")))
      (user-error "Refused: the approval queue answers only Cal's own clicks"))
    (with-current-buffer buf
      (let* ((pos (claude-click--place label position))
             (window (get-buffer-window buf t))
             (command nil))
        (save-excursion
          (goto-char pos)
          (claude-click--guard pos))
        (goto-char pos)
        (when window (homun-layout-point window pos))
        (let ((map (get-char-property pos 'keymap)))
          ;; A widget follows the mouse itself (down-mouse-1 reads events); its press
          ;; at point is the same action without the tracking
          (setq command (or (and map (let ((c (lookup-key map [mouse-1]))) (and (commandp c) c)))
                            (and map (lookup-key map [down-mouse-1])
                                 (let ((c (lookup-key map (kbd "RET")))) (and (commandp c) c)))
                            (key-binding [mouse-1] t nil pos))))
        (unless (commandp command) (user-error "Nothing to press at %d" pos))
        (if (eq command 'mouse-set-point)
            (user-error "Nothing to press at %d" pos)
          (let ((event (list 'mouse-1 (if (and window (ignore-errors (posn-at-point pos window)))
                                          (posn-at-point pos window)
                                        (list nil pos '(0 . 0) 0)))))
            (setq last-nonmenu-event nil)
            (call-interactively command nil (vector event))))
        (format "%s at %d" command pos)))))

(provide 'claude-click)
;;; claude-click.el ends here
