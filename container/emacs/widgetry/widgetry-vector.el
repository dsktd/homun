;;; widgetry-vector.el --- A row of sliders for a vector -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; A `widget' for a vector of two or three numbers, shown as a row of
;; X, Y and Z sliders.  Its value is the vector; `:notify' runs once per
;; change by the user, with the whole vector in `widget-value'.
;;
;;   (widget-create 'widgetry-vector :value [1.0 2.5 -0.5]
;;                  :notify (lambda (widget &rest _)
;;                            (message "%S" (widget-value widget))))

;;; Code:

(require 'widgetry-slider)

(define-widget 'widgetry-vector 'default
  "A vector of two or three numbers."
  :value [0.0 0.0 0.0]
  ;; Change per pixel dragged of every component; nil uses the global step.
  :step nil
  :widgetry-type '(vector)
  :format "%v"
  :value-create #'widgetry-vector--value-create
  :value-delete #'widget-children-value-delete
  :value-get #'widgetry-vector--value-get)

(defconst widgetry-vector--types
  '(widgetry-slider-x widgetry-slider-y widgetry-slider-z)
  "The slider type of each component.")

(defun widgetry-vector--value-create (widget)
  "Insert a slider for each component of WIDGET."
  (let ((value (widget-get widget :value))
        children)
    (dotimes (i (length value))
      (when (> i 0) (widget-insert "  "))
      (push (widget-create-child-and-convert
             widget (nth i widgetry-vector--types)
             :value (aref value i)
             :step (widget-get widget :step)
             :notify (lambda (&rest _) (widget-apply widget :notify widget)))
            children))
    (widget-put widget :children (nreverse children))))

(defun widgetry-vector--value-get (widget)
  "The vector of the values of the sliders of WIDGET."
  (vconcat (mapcar #'widget-value (widget-get widget :children))))

(provide 'widgetry-vector)
;;; widgetry-vector.el ends here
