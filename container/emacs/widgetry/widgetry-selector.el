;;; widgetry-selector.el --- A choose-one widget -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; A `widget' for one of a list of :choices, shown as "◀ choice ▶" in a
;; block as wide as the widest choice.  h, l, left and right (and a
;; click, or a right click back) step through the choices; dragging steps
;; once per `widgetry-drag-threshold' pixels, right or up going forward.
;;
;;   (widget-create 'widgetry-selector :value "Soft"
;;                  :choices '("Off" "Hard" "Soft"))

;;; Code:

(require 'cl-lib)
(require 'widgetry-core)

(defface widgetry-selector-tag
  '((t (:inherit widgetry-tag)))
  "Face for the tag of a selector."
  :group 'widgetry)

(defface widgetry-selector-value
  '((t (:inherit widgetry-value)))
  "Face for the value of a selector on every second choice."
  :group 'widgetry)

(defface widgetry-selector-value-alt
  '((t (:inherit widgetry-value)))
  "Face for the value of a selector on the other choices.
A drag fills the value with the face of the choice it moves towards, so
the two shades take turns: it stays filled once a step ticks over, and
the next step fills it back with the first shade."
  :group 'widgetry)

(defvar widgetry-selector-map
  (let ((map (make-sparse-keymap)))
    (dolist (key (list "h" [left] [mouse-3]))
      (define-key map key #'widgetry-selector-previous))
    (dolist (key (list "l" [right] (kbd "RET") (kbd "SPC")))
      (define-key map key #'widgetry-selector-next))
    (define-key map [down-mouse-1] #'widgetry-selector-drag)
    (define-key map [down-mouse-3] #'ignore)
    map)
  "Keymap for selector widgets.")

(define-widget 'widgetry-selector 'item
  "One of :choices."
  :choices nil
  ;; How far a drag is towards the next choice, 0.0 to 1.0, while dragged.
  :fill nil
  :keymap widgetry-selector-map
  :hoverable t
  :widgetry-type '(selector)
  :value-create #'widgetry-insert
  :value-set #'widgetry-value-set
  :parts #'widgetry-selector--parts
  :suppress-face t
  :tag " ☰ "
  :tag-face 'widgetry-selector-tag
  :format "%v")

(defun widgetry-selector--label (widget)
  "The value of WIDGET centred in the width of its widest choice."
  (let* ((choice (format "%s" (widget-value widget)))
         (width (apply #'max (string-width choice)
                       (mapcar (lambda (choice) (string-width (format "%s" choice)))
                               (widget-get widget :choices))))
         (pad (- width (string-width choice))))
    (concat (make-string (/ pad 2) ?\s) choice (make-string (- pad (/ pad 2)) ?\s))))

(defun widgetry-selector--progress (distance &optional threshold)
  "How far DISTANCE pixels is towards the next step, 0.0 up to 1.0.
Negative distances count from the step before, so dragging back empties
the fill and then steps backwards."
  (let ((threshold (or threshold widgetry-drag-threshold)))
    (/ (float (- distance (* threshold (floor distance threshold)))) threshold)))

(defun widgetry-selector--shade (index)
  "The face of the value of the choice at INDEX: two shades alternate."
  (if (cl-evenp index) 'widgetry-selector-value 'widgetry-selector-value-alt))

(defun widgetry-selector--index (widget)
  "Position of the value of WIDGET among its choices, or 0."
  (or (cl-position (widget-value widget) (widget-get widget :choices) :test #'equal) 0))

(defun widgetry-selector--text (widget)
  "The text of the value block of WIDGET."
  (format " ◀ %s ▶ " (widgetry-selector--label widget)))

(defun widgetry-selector--parts (widget)
  "The look of WIDGET: its tag and value.
While dragged, the value fills from the left with the shade of the next
choice, in proportion to the drag."
  (let ((index (widgetry-selector--index widget)))
    (list (list (widget-get widget :tag) (widget-get widget :tag-face))
          (list (widgetry-selector--text widget) (widgetry-selector--shade index)
                (or (widget-get widget :fill) 0.0) (widgetry-selector--shade (1+ index))))))

(defun widgetry-selector--choice (widget from steps)
  "The choice STEPS after the choice FROM in WIDGET, wrapping around."
  (let* ((choices (widget-get widget :choices))
         (index (or (cl-position from choices :test #'equal) 0)))
    (nth (mod (+ index steps) (length choices)) choices)))

(defun widgetry-selector--step (widget steps)
  "Move WIDGET STEPS choices, as a change by the user."
  (widgetry-notify widget (widgetry-selector--choice widget (widget-value widget) steps)))

(defun widgetry-selector-next (&optional event)
  "Select the next choice of the selector at point, or under the mouse EVENT."
  (interactive (list last-nonmenu-event))
  (widgetry-selector--step (widgetry-widget-at event 'selector) 1))

(defun widgetry-selector-previous (&optional event)
  "Select the previous choice of the selector at point, or under EVENT."
  (interactive (list last-nonmenu-event))
  (widgetry-selector--step (widgetry-widget-at event 'selector) -1))

(defun widgetry-selector-drag (event)
  "Drag the selector under EVENT: one choice per `widgetry-drag-threshold'.
The value fills towards the next choice as it is dragged.  A click
without dragging selects the next choice."
  (interactive "e")
  (let* ((widget (widgetry-widget-at event 'selector))
         (start (widget-value widget)))
    (widget-put widget :initial start)
    (unwind-protect
        (progn
          (unless (widgetry-drag
                   (lambda (distance)
                     (let ((choice (widgetry-selector--choice
                                    widget start (floor distance widgetry-drag-threshold))))
                       (widget-put widget :fill (widgetry-selector--progress distance))
                       (widgetry-flash widget)
                       (if (equal choice (widget-value widget))
                           (widgetry-set widget choice)
                         (widgetry-notify widget choice)))))
            (widget-put widget :fill nil)
            (widgetry-selector--step widget 1))
          (when (widget-get widget :fill)
            (widget-put widget :fill nil)
            (widgetry-set widget (widget-value widget))))
      (widget-put widget :fill nil)
      (widget-put widget :initial nil))))

(provide 'widgetry-selector)
;;; widgetry-selector.el ends here
