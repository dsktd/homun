;;; homun-button.el --- Every Homun button is a widgetry button -*- lexical-binding: t -*-

;; The board's Recreate, Compact, Settings and Finished are widgetry buttons, drawn by
;; `widgetry-display' (an SVG pill on a graphic frame, themed text cells elsewhere).  This is a thin
;; layer over that one renderer: a role is a face, and roles differ by colour only, never by shape.
;; `homun-button' gives a button as a string, for a header, tab or mode line or any text;
;; `homun-button-insert' makes a live widget in a widgetry buffer.  With PHONE the string is padded
;; to thumb height (48 dp).

;;; Code:

(require 'widgetry-core)
(require 'widgetry-button)

(defgroup homun-button nil "Homun's buttons." :group 'faces)

;; An absolute :height (1/10 pt), so the phone's text size steps never shrink a button
(defface homun-button-base '((t :height 130))
  "What every role inherits: the button size, fixed (13 pt) whatever the text size.")

(defface homun-button-primary '((t :inherit (homun-button-base widgetry-button-fill-choice)))
  "The one action a view is for: Send, Allow.")
(defface homun-button-secondary '((t :inherit (homun-button-base widgetry-button-value)))
  "Every other action: Cancel, To ▾.")
(defface homun-button-danger '((t :inherit (homun-button-base widgetry-button-fill)))
  "An action that loses something: Deny, Drop.")
(defface homun-button-tab '((t :inherit (homun-button-base shadow widgetry-button-value)))
  "A tab of a view not shown.")
(defface homun-button-tab-active '((t :inherit (homun-button-base widgetry-value-on)))
  "The tab of the view shown.")
(defface homun-button-chip '((t :inherit (homun-button-base widgetry-button-value)))
  "A choice not taken.")
(defface homun-button-chip-selected '((t :inherit (homun-button-base widgetry-value-on)))
  "A choice taken.")
(defface homun-button-link '((t :inherit (homun-button-base link widgetry-button-value) :underline nil))
  "Text that goes somewhere.")
(defface homun-button-disabled '((t :inherit (homun-button-base widgetry-button-disabled)))
  "A button that does nothing now.")
(defface homun-button-busy '((t :inherit (homun-button-base warning widgetry-button-value)))
  "A pressed button whose command still runs; its label ends in \"…\".")

(defconst homun-button-roles
  '(primary secondary danger tab tab-active chip chip-selected link disabled busy)
  "Every role, in specimen order.")

(defun homun-button--face (role)
  (intern (format "homun-button-%s" role)))

(defun homun-button--touch (frame)
  "The vertical margin that makes a button of FRAME's line height 48 dp tall."
  (let* ((mm (display-mm-height frame))
         (px (if (and mm (> mm 0))
                 (round (* 48 (/ (/ (display-pixel-height frame) (/ mm 25.4)) 160.0)))
               (* 3 (frame-char-height frame)))))
    (max 0 (/ (- px (frame-char-height frame)) 2))))

(defun homun-button--keymap (action phone)
  (let ((map (make-sparse-keymap))
        ;; A click in a header or tab line acts in that window's buffer, which need not be current
        (act (lambda (&optional event)
               (interactive (list last-nonmenu-event))
               (let ((window (and (mouse-event-p event) (posn-window (event-start event)))))
                 (with-current-buffer (if (window-live-p window) (window-buffer window) (current-buffer))
                   (if (commandp action) (call-interactively action) (funcall action)))))))
    (define-key map [mouse-1] act)
    (define-key map (kbd "RET") act)
    (dolist (line '(header-line tab-line mode-line))
      (define-key map (vector line 'mouse-1) act))
    ;; A touch in the header acts at once: it can hide the keyboard, which resizes the frame
    ;; before the touch ends
    (when phone
      (dolist (line '(header-line tab-line mode-line))
        (define-key map (vector line 'touchscreen-begin) act)))
    map))

(defun homun-button (label role &optional action phone)
  "LABEL as a widgetry button of ROLE (see `homun-button-roles') running ACTION on
a click.
ACTION is a command or a function of no arguments; nil makes a button that only
shows. PHONE pads a graphic one to thumb height."
  (let* ((frame (widgetry--frame (current-buffer)))
         (text (concat " " label (if (eq role 'busy) "…" "") " "))
         (shown (widgetry-display (list (list text (homun-button--face role) nil nil nil)) frame))
         (string (if (stringp shown)
                     (copy-sequence shown)
                   (propertize text 'display
                               (if phone
                                   (append shown (list :margin (cons 0 (homun-button--touch frame))))
                                 shown)))))
    (when (and action (not (memq role '(disabled busy))))
      (add-text-properties 0 (length string)
                           (list 'keymap (homun-button--keymap action phone)
                                 'mouse-face 'highlight 'pointer 'hand)
                           string))
    (put-text-property 0 (length string) 'homun-button-role role string)
    string))

(defun homun-button-insert (label role action)
  "Insert LABEL as a live widgetry button of ROLE whose press calls ACTION (no
arguments)."
  (widget-create 'widgetry-button :tag nil :value (concat " " label " ")
                 :label-face (homun-button--face role)
                 :disabled (and (memq role '(disabled busy)) t)
                 :notify (lambda (&rest _) (funcall action))))

(defun homun-button-specimen (&optional phone)
  "Show every role, at the phone size with a prefix argument."
  (interactive "P")
  (with-current-buffer (get-buffer-create "*homun-buttons*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (dolist (role homun-button-roles)
        (insert (propertize (format "%-15s" role) 'face 'shadow)
                (homun-button (capitalize (symbol-name role)) role #'ignore phone) "\n\n")))
    (goto-char (point-min))
    (special-mode)
    (pop-to-buffer-same-window (current-buffer))))

(provide 'homun-button)
;;; homun-button.el ends here
