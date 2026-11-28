;;; widgetry-toggle.el --- An on/off widget -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; A `widget' for a boolean: a tag and an ON or OFF value, flipped by
;; RET, SPC or a click, or by dragging: it flips once per
;; `widgetry-drag-threshold' pixels dragged.
;;
;;   (widget-create 'widgetry-toggle :value t
;;                  :notify (lambda (widget &rest _)
;;                            (message "%s" (widget-value widget))))

;;; Code:

(require 'cl-lib)
(require 'widgetry-core)

(defface widgetry-toggle-tag
  '((t (:inherit widgetry-tag)))
  "Face for the tag of a toggle."
  :group 'widgetry)

(defface widgetry-toggle-on-tag
  '((t ( :inherit widgetry-toggle-tag)))
  "Face for the tag of a toggle that is on."
  :group 'widgetry)

(defun widgetry-toggle--tag-face (on face)
  "The face of the tag of a toggle: the on face if ON, else FACE."
  (if on 'widgetry-toggle-on-tag face))

(defvar widgetry-toggle-map
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1] #'widgetry-toggle-drag)
    (define-key map (kbd "RET") #'widgetry-toggle-flip)
    (define-key map (kbd "SPC") #'widgetry-toggle-flip)
    map)
  "Keymap for toggle widgets.")

(define-widget 'widgetry-toggle 'item
  "An on/off value."
  :keymap widgetry-toggle-map
  :hoverable t
  :widgetry-type '(toggle)
  :value-create #'widgetry-insert
  :value-set #'widgetry-value-set
  :parts #'widgetry-toggle--parts
  :suppress-face t
  :tag " ⏻ "
  :tag-face 'widgetry-toggle-tag
  :format "%v")

(defun widgetry-toggle--parts (widget)
  "The look of WIDGET: its tag and ON or OFF."
  (let ((on (widget-value widget)))
    (list (list (widget-get widget :tag)
                (widgetry-toggle--tag-face on (widget-get widget :tag-face)))
          (list (if on " ON  " " OFF ") (if on 'widgetry-value-on 'widgetry-value)))))

(defun widgetry-toggle--set (widget value)
  "Set WIDGET to VALUE, a change by the user if it differs."
  (let ((value (and value t)))
    (unless (eq value (and (widget-value widget) t))
      (widgetry-notify widget value))))

(defun widgetry-toggle-flip (&optional event)
  "Flip the toggle at point, or under the mouse EVENT."
  (interactive (list last-nonmenu-event))
  (let ((widget (widgetry-widget-at event 'toggle)))
    (widgetry-toggle--set widget (not (widget-value widget)))))

(defun widgetry-toggle-drag (event)
  "Drag the toggle under EVENT: it flips once per `widgetry-drag-threshold'.
A click without dragging flips it."
  (interactive "e")
  (let* ((widget (widgetry-widget-at event 'toggle))
         (start (widget-value widget)))
    (widget-put widget :initial start)
    (unwind-protect
        (unless (widgetry-drag
                 (lambda (distance)
                   ;; Every step flips it, like a selector of two
                   (widgetry-flash widget)
                   (widgetry-toggle--set
                    widget (if (cl-oddp (widgetry-steps distance)) (not start) start))))
          (widgetry-toggle--set widget (not start)))
      (widget-put widget :initial nil))))

(provide 'widgetry-toggle)
;;; widgetry-toggle.el ends here
