;;; widgetry-selection.el --- A selection group: the one state of a list's checkboxes -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;;; Commentary:

;; A list of rows, each with a checkbox, and a header with a master box: the group
;; owns which ids are selected, and the rows and the header both draw from it.
;;
;;   (setq sel (widgetry-selection-create '(a b c) (lambda (_) (redraw))))
;;   (widgetry-selection-toggle sel 'b)      ; one row
;;   (widgetry-selection-toggle-all sel)     ; the master box: all, or none when all were
;;   (widgetry-selection-state sel)          ; none, some or all: the master's look
;;   (widgetry-selection-summary sel)        ; "1 of 3 selected"
;;
;; `widgetry-selection-tint' gives a selected row's line a light accent background.

;;; Code:

(require 'cl-lib)
(require 'widgetry-core)

(cl-defstruct (widgetry-selection (:constructor widgetry-selection--make))
  "The ids of a list, those selected, and the function called with the group on a change."
  ids selected notify)

(defun widgetry-selection-create (ids &optional notify)
  "A group over IDS, nothing selected; NOTIFY is called with it after each change."
  (widgetry-selection--make :ids ids :notify notify))

(defun widgetry-selection--changed (sel)
  (when-let* ((f (widgetry-selection-notify sel))) (funcall f sel)))

(defun widgetry-selection-selected-p (sel id)
  (and (member id (widgetry-selection-selected sel)) t))

(defun widgetry-selection-set-ids (sel ids)
  "Make IDS the rows of SEL, keeping the selection of those that stay."
  (setf (widgetry-selection-ids sel) ids
        (widgetry-selection-selected sel)
        (cl-remove-if-not (lambda (id) (member id ids)) (widgetry-selection-selected sel))))

(defun widgetry-selection-toggle (sel id)
  "Select ID in SEL, or clear it."
  (setf (widgetry-selection-selected sel)
        (if (widgetry-selection-selected-p sel id)
            (remove id (widgetry-selection-selected sel))
          (cl-remove-if-not (lambda (i) (or (equal i id) (widgetry-selection-selected-p sel i)))
                            (widgetry-selection-ids sel))))
  (widgetry-selection--changed sel))

(defun widgetry-selection-toggle-all (sel)
  "Select every row of SEL, or none when every one already is."
  (setf (widgetry-selection-selected sel)
        (unless (eq (widgetry-selection-state sel) 'all) (copy-sequence (widgetry-selection-ids sel))))
  (widgetry-selection--changed sel))

(defun widgetry-selection-state (sel)
  "none, some or all."
  (let ((n (length (widgetry-selection-selected sel))) (m (length (widgetry-selection-ids sel))))
    (cond ((zerop n) 'none) ((= n m) 'all) (t 'some))))

(defun widgetry-selection-summary (sel)
  (format "%d of %d selected" (length (widgetry-selection-selected sel))
          (length (widgetry-selection-ids sel))))

(defface widgetry-selection-row '((t (:inherit widgetry-button-fill-choice)))
  "Face whose background, faded into the default one, tints a selected row."
  :group 'widgetry)

(defvar widgetry-selection-tint-amount 0.18 "How much of the accent goes into a row's tint.")

(defun widgetry-selection-tint (beg end)
  "Tint the lines from BEG to END as a selected row; return the overlay."
  (let* ((frame (widgetry--frame (current-buffer)))
         (bg (widgetry--blend (car (widgetry--paint 'widgetry-selection-row frame))
                              (car (widgetry--paint 'default frame))
                              (- 1 widgetry-selection-tint-amount)))
         (o (make-overlay beg end)))
    (overlay-put o 'face `(:background ,bg :extend t))
    (overlay-put o 'widgetry-selection-tint t)
    (overlay-put o 'evaporate t)
    o))

(provide 'widgetry-selection)
;;; widgetry-selection.el ends here
