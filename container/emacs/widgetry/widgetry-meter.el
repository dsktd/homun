;;; widgetry-meter.el --- A bar showing a number in a range -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; A `widget' for a number between :min (default 0) and :max (default
;; 1): a tag, a bar :width characters wide (default 12), filled in
;; proportion to the value, and the percentage.  Like a slider it is
;; changed by dragging (the whole bar is the range) or by typing, and
;; `:notify' runs on every change by the user.  In a graphic frame the
;; fill follows the value to the pixel; in a terminal it ends in an
;; eighth-block glyph.
;;
;; With :read-only non-nil the meter is only a display: it has no keymap,
;; so it cannot be dragged or typed over, and it never runs :notify.
;; :fill-face names the face of the fill (default `widgetry-meter-fill');
;; `widgetry-meter-fill-ok', `-warn' and `-high' are green, amber and red.
;;
;;   (widget-create 'widgetry-meter :value 0.4
;;                  :notify (lambda (widget &rest _)
;;                            (message "%s" (widget-value widget))))

;;; Code:

(require 'widgetry-slider)

(defface widgetry-meter-tag
  '((t (:inherit widgetry-slider-tag)))
  "Face for the tag of a meter."
  :group 'widgetry)

(defface widgetry-meter-fill
  '((t ( :inherit widgetry-slider-value)))
  "Face for the filled part of the bar of a meter."
  :group 'widgetry)

(defface widgetry-meter-fill-ok
  '((t (:inherit widgetry-meter-fill)))
  "Face for the fill of a meter in the green."
  :group 'widgetry)

(defface widgetry-meter-fill-warn
  '((t (:inherit widgetry-meter-fill)))
  "Face for the fill of a meter in the amber."
  :group 'widgetry)

(defface widgetry-meter-fill-high
  '((t (:inherit widgetry-meter-fill)))
  "Face for the fill of a meter in the red."
  :group 'widgetry)

(defun widgetry-meter-level-face (fraction)
  "The fill face for FRACTION used: green below 0.6, amber below 0.85, red above."
  (cond ((< fraction 0.6) 'widgetry-meter-fill-ok)
        ((< fraction 0.85) 'widgetry-meter-fill-warn)
        (t 'widgetry-meter-fill-high)))

(defun widgetry-meter-string (fraction width &optional fill-face)
  "A bar WIDTH cells wide for FRACTION as plain-text glyphs, with the fill's
colour.
For a header line, a table cell or a text render: full blocks, an eighth
block at the edge, ░ for the rest.  FILL-FACE defaults by level."
  (let* ((eighths (round (* (max 0.0 (min 1.0 fraction)) 8 width)))
         (full (/ eighths 8))
         (edge (% eighths 8))
         (colour (face-background (or fill-face (widgetry-meter-level-face fraction)) nil t)))
    (concat (propertize (concat (make-string full ?█)
                                (if (> edge 0) (substring widgetry-eighths edge (1+ edge)) ""))
                        'face (and colour `(:foreground ,colour)))
            (make-string (- width full (if (> edge 0) 1 0)) ?░))))

(defvar widgetry-meter-map
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1] #'widgetry-meter-drag)
    (set-keymap-parent map widgetry-slider-map)
    map)
  "Keymap for meter widgets: the slider keys, dragging over the bar.")

(define-widget 'widgetry-meter 'widgetry-slider
  "A number in a range, shown as a bar."
  :min 0.0
  :max 1.0
  :width 12
  :reflow t
  :value 0.0
  :keymap widgetry-meter-map
  :read-only nil
  :fill-face 'widgetry-meter-fill
  :widgetry-type '(slider meter)
  :parts #'widgetry-meter--parts
  :value-set #'widgetry-meter--value-set
  :tag " ▅ "
  :tag-face 'widgetry-meter-tag)

(defun widgetry-meter--fraction (value min max)
  "Where VALUE is between MIN and MAX, from 0.0 to 1.0."
  (if (<= max min)
      0.0
    (max 0.0 (min 1.0 (/ (float (- value min)) (- max min))))))

(defun widgetry-meter--pixels (widget)
  "The pixel width of the bar of WIDGET."
  (* (widgetry-meter--cells widget) (frame-char-width)))

(defun widgetry-meter--cells (widget)
  "The cells of the bar of WIDGET: its :width, less when the window is narrower."
  (widgetry-fit-cells widget (widget-get widget :width) (string-width (widget-get widget :tag))))

(defun widgetry-meter--parts (widget)
  "The look of WIDGET: its tag and the bar, its percentage at the right end."
  (let* ((fraction (widgetry-meter--fraction (widget-value widget)
                                             (widget-get widget :min) (widget-get widget :max)))
         (label (format " %3d%% " (round (* fraction 100)))))
    (list (if (widgetry-graphic-p (widgetry--frame (current-buffer)))
              ;; Blank text of the tag's width: the bars are drawn over it.
              (list (make-string (string-width (widget-get widget :tag)) ?\s)
                    (widget-get widget :tag-face) nil nil (list :bars fraction))
            (list (widget-get widget :tag) (widget-get widget :tag-face)))
          (list (concat (make-string (max 0 (- (widgetry-meter--cells widget) (length label))) ?\s)
                        label)
                'widgetry-slider-value fraction (widget-get widget :fill-face)))))

(defun widgetry-meter--value-set (widget value)
  "Set WIDGET to VALUE kept within :min and :max, as a slider does.
A read-only meter never notifies."
  (let ((value (max (widget-get widget :min) (min (widget-get widget :max) value))))
    (if (widget-get widget :read-only)
        (widgetry-value-set widget value)
      (widgetry-slider--value-set widget value))))

(defun widgetry-meter-drag (event)
  "Drag the meter under EVENT: the width of the bar is its whole range."
  (interactive "e")
  (let* ((widget (widgetry-widget-at event 'meter))
         (start (widget-value widget))
         (per-pixel (/ (- (widget-get widget :max) (widget-get widget :min))
                       (float (max 1 (* (widgetry-cell-scale)
                                        (widgetry-meter--pixels widget)))))))
    (widget-put widget :initial start)
    (unwind-protect
        (widgetry-drag (lambda (distance)
                         (widgetry-set
                         widget (widgetry-round (+ start (* per-pixel distance))
                                                (widgetry-slider--decimals widget))))
                       t)
      (widgetry-slider--finish widget))))

(provide 'widgetry-meter)
;;; widgetry-meter.el ends here
