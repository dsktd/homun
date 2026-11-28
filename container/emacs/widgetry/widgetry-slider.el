;;; widgetry-slider.el --- A draggable number slider widget -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; A `widget' for a number: a coloured tag and the value, changed by
;; dragging the mouse across it or by typing digits over it.
;;
;;   (widget-create 'widgetry-slider-x :value 1.0
;;                  :notify (lambda (widget &rest _)
;;                            (message "x = %s" (widget-value widget))))
;;
;; While the value is being dragged or typed, the widget is "editing":
;; `:initial' holds the value it started from, so C-g (or ESC) puts it
;; back, RET keeps the typed one.  `:notify' runs on every change made by
;; the user, so a caller can apply it live.

;;; Code:

(require 'widgetry-core)

(defcustom widgetry-slider-magnitude-width 5
  "Characters of the number of a slider without :min and :max, as in 99.99."
  :type 'natnum
  :group 'widgetry)

(defcustom widgetry-slider-drag-step 0.01
  "How much the value changes per pixel dragged."
  :type 'number
  :group 'widgetry)

;;;; Precision

(defun widgetry-slider--step (widget)
  "How much WIDGET changes per pixel dragged: its :step, else the global one."
  (or (widget-get widget :step) widgetry-slider-drag-step))

(defun widgetry-slider--decimals (widget)
  "Decimal places of WIDGET: its :decimals, else those of its drag step."
  (or (widget-get widget :decimals)
      (max 0 (round (- (log (widgetry-slider--step widget) 10))))))

(defun widgetry-round (value decimals)
  "VALUE rounded to DECIMALS places, as the nearest float (no noise)."
  (let ((scale (expt 10 decimals)))
    (/ (round (* value scale)) (float scale))))

;;;; Faces

(defface widgetry-slider-tag
  '((t (:inherit widgetry-tag)))
  "Face for the tag of a slider."
  :group 'widgetry)

(defface widgetry-sign
  '((t (:inherit widgetry-value)))
  "Face for the sign column of a number, between the tag and the value."
  :group 'widgetry)

(defface widgetry-slider-x
  '((t ( :inherit widgetry-slider-tag
         :weight bold)))
  "Face for the tag of an X axis slider."
  :group 'widgetry)

(defface widgetry-slider-y
  '((t ( :inherit widgetry-slider-tag
         :weight bold)))
  "Face for the tag of a Y axis slider."
  :group 'widgetry)

(defface widgetry-slider-z
  '((t ( :inherit widgetry-slider-tag
         :weight bold)))
  "Face for the tag of a Z axis slider."
  :group 'widgetry)

(defface widgetry-slider-value
  '((t (:inherit widgetry-value)))
  "Face for the value of a slider."
  :group 'widgetry)

;;;; Keymap

(defvar widgetry-slider-map
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1] #'widgetry-slider-drag)
    (define-key map (kbd "RET") #'widgetry-slider-submit)
    (define-key map (kbd "C-g") #'widgetry-slider-cancel)
    (dolist (key '(?0 ?1 ?2 ?3 ?4 ?5 ?6 ?7 ?8 ?9 ?. ?-))
      (define-key map (vector key) #'widgetry-slider-input))
    (define-key map (kbd "<backspace>") #'widgetry-slider-delete)
    (define-key map (kbd "DEL") #'widgetry-slider-delete)
    (when (fboundp 'evil-define-key*)
      (evil-define-key* nil map (kbd "ESC") #'widgetry-slider-cancel))
    map)
  "Keymap for slider widgets.")

;;;; Widgets

(define-widget 'widgetry-slider 'item
  "A number, changed by dragging or typing."
  ;; The value before the user started changing it, while editing.
  :initial nil
  ;; Decimal places of dragged values; nil derives it from the drag step.
  :decimals nil
  ;; Change per pixel dragged; nil uses `widgetry-slider-drag-step'.
  :step nil
  ;; The characters typed so far, while typing.
  :current nil
  :keymap widgetry-slider-map
  :widgetry-type '(slider)
  :value-create #'widgetry-insert
  :parts #'widgetry-slider--parts
  :value-set #'widgetry-slider--value-set
  :suppress-face t
  :tag " ↔ "
  :tag-face 'widgetry-slider-tag
  :format "%v")

(define-widget 'widgetry-slider-x 'widgetry-slider
  "A slider for an X axis."
  :tag " X "
  :tag-face 'widgetry-slider-x)

(define-widget 'widgetry-slider-y 'widgetry-slider
  "A slider for a Y axis."
  :tag " Y "
  :tag-face 'widgetry-slider-y)

(define-widget 'widgetry-slider-z 'widgetry-slider
  "A slider for a Z axis."
  :tag " Z "
  :tag-face 'widgetry-slider-z)

(defun widgetry-slider--sign-magnitude (value decimals width)
  "The sign and the magnitude of VALUE as a cons of strings.
The sign is \"+\" or \"−\" for a number that does not show as zero, else
a space.  The magnitude has DECIMALS places, right-aligned in WIDTH."
  (let ((magnitude (format (format "%%.%df" decimals) (abs value))))
    (cons (cond ((not (string-match-p "[1-9]" magnitude)) " ")
                  ((< value 0) "−")
                  (t "+"))
          (string-pad magnitude width nil t))))

(defun widgetry-slider--width (widget)
  "Characters of the magnitude of WIDGET: from :min and :max, else the default."
  (let ((min (widget-get widget :min))
        (max (widget-get widget :max))
        (decimals (widgetry-slider--decimals widget)))
    (if (and (numberp min) (numberp max))
        (apply #'max (mapcar (lambda (n) (length (format (format "%%.%df" decimals) (abs n))))
                             (list min max)))
      widgetry-slider-magnitude-width)))

(defun widgetry-slider--parts (widget)
  "The look of WIDGET: its tag, the sign column and the number."
  (let* ((decimals (if (widget-get widget :current)
                       ;; As many places as typed
                       (length (cadr (split-string (apply #'string (widget-get widget :current))
                                                   "\\.")))
                     (widgetry-slider--decimals widget)))
         (parts (widgetry-slider--sign-magnitude (widget-value widget) decimals
                                        (widgetry-slider--width widget))))
    (list (list (widget-get widget :tag) (widget-get widget :tag-face))
          (list (car parts) 'widgetry-sign)
          (list (concat (cdr parts) " ") 'widgetry-slider-value))))

(defun widgetry-slider--value-set (widget value)
  "Set WIDGET to VALUE; tell its `:notify' when the user is changing it."
  (widgetry-value-set widget value)
  (when (widget-get widget :initial)
    (widgetry-flash widget)
    (widget-apply widget :notify widget)))

;;;; Commands

(defun widgetry-slider--at-point ()
  "The slider at point, or an error."
  (widgetry-widget-at nil 'slider))

(defun widgetry-slider--edit (widget current)
  "Start editing WIDGET if it is not yet, and set the typed characters to CURRENT."
  (unless (widget-get widget :initial)
    (widget-put widget :initial (widget-value widget)))
  (widget-put widget :current current)
  (widgetry-set widget (widgetry-slider--clamp widget (widgetry-slider--typed widget current))))

(defun widgetry-slider--clamp (widget value)
  "VALUE kept within the :min and :max of WIDGET, where set."
  (let ((min (widget-get widget :min))
        (max (widget-get widget :max)))
    (cond ((and min (< value min)) min)
          ((and max (> value max)) max)
          (t value))))

(defun widgetry-slider--set (widget value)
  "Set WIDGET to VALUE within its :min and :max."
  (widgetry-set widget (widgetry-slider--clamp widget value)))

(defun widgetry-slider--typed (widget current)
  "The number typed as the characters CURRENT, to the places of WIDGET."
  (widgetry-round (float (string-to-number (apply #'string current)))
                  (widgetry-slider--decimals widget)))

(defun widgetry-slider--finish (widget)
  "Stop editing WIDGET."
  (widget-put widget :initial nil)
  (widget-put widget :current nil))

(defun widgetry-slider-input ()
  "Type the key pressed into the slider at point.
A second decimal point, or a minus after the first character, is ignored."
  (interactive)
  (let* ((widget (widgetry-slider--at-point))
         (current (and (widget-get widget :initial) (widget-get widget :current)))
         (char last-command-event))
    (widgetry-slider--edit
     widget
     (cond ((and (eq char ?.) (memq ?. current)) current)
           ((and (eq char ?-) current) current)
           (t (append current (list char)))))))

(defun widgetry-slider-delete ()
  "Delete the last character typed into the slider at point."
  (interactive)
  (let ((widget (widgetry-slider--at-point)))
    (widgetry-slider--edit widget (butlast (and (widget-get widget :initial)
                                                (widget-get widget :current))))))

(defun widgetry-slider-cancel ()
  "Put the slider at point back to its value before editing."
  (interactive)
  (let* ((widget (widgetry-slider--at-point))
         (initial (widget-get widget :initial)))
    (widgetry-slider--finish widget)
    (when initial
      (widgetry-set widget initial))))

(defun widgetry-slider-submit ()
  "Keep the value typed into the slider at point."
  (interactive)
  (let ((widget (widgetry-slider--at-point)))
    (when-let* ((current (widget-get widget :current)))
      (widget-put widget :current nil)
      (widgetry-set widget (widgetry-slider--clamp widget (widgetry-slider--typed widget current))))
    (widgetry-slider--finish widget)))

(defun widgetry-slider-drag (event)
  "Drag the slider under EVENT: right or up raises the value."
  (interactive "e")
  (let* ((widget (widgetry-widget-at event 'slider))
         (start-value (widget-value widget)))
    (widget-put widget :initial start-value)
    (unwind-protect
        (widgetry-drag (lambda (distance)
                         (widgetry-slider--set
                         widget (widgetry-round
                                 (+ start-value (* (widgetry-slider--step widget) distance))
                                 (widgetry-slider--decimals widget)))))
      (widgetry-slider--finish widget))))

(provide 'widgetry-slider)
;;; widgetry-slider.el ends here
