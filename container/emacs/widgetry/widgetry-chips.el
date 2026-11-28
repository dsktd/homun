;;; widgetry-chips.el --- A multi-select row of chips -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; A `widget' for a subset of its :choices (symbols), shown as a row of
;; chips, each on or off.  RET or SPC (or a click) toggles the chip at
;; point; h and l (or left and right) move between chips.  The value is
;; the list of chosen symbols, in the order of :choices.  With :checkbox
;; non-nil each chip shows a box, ☐ off and ☑ on, as a checkbox group;
;; `widgetry-check' is one such box alone.
;;
;;   (widget-create 'widgetry-chips :value '(border tick)
;;                  :choices '(border flash tick sweep)
;;                  :notify (lambda (widget &rest _)
;;                            (message "%S" (widget-value widget))))

;;; Code:

(require 'cl-lib)
(require 'widgetry-core)

(defface widgetry-chips-tag
  '((t (:inherit widgetry-tag)))
  "Face for the tag of a row of chips."
  :group 'widgetry)

(defvar widgetry-chips-map
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1] #'widgetry-chips-toggle)
    (define-key map (kbd "RET") #'widgetry-chips-toggle)
    (define-key map (kbd "SPC") #'widgetry-chips-toggle)
    (dolist (key (list "h" [left]))
      (define-key map key #'widgetry-chips-previous))
    (dolist (key (list "l" [right]))
      (define-key map key #'widgetry-chips-next))
    map)
  "Keymap for chips widgets.")

(define-widget 'widgetry-chips 'item
  "A subset of :choices."
  :reflow t
  :choices nil
  :checkbox nil
  :single nil
  :labels nil
  :disabled nil
  :keymap widgetry-chips-map
  :hoverable t
  :hover-own t
  :hover-key #'widgetry-chips--hover-key
  :widgetry-type '(chips)
  :value-create #'widgetry-insert
  :value-set #'widgetry-value-set
  :parts #'widgetry-chips--parts
  :suppress-face t
  :tag " ◈ "
  :tag-face 'widgetry-chips-tag
  :format "%v")

(defun widgetry-chips--label (widget choice)
  "The text of the chip of CHOICE in WIDGET: a box first when it is a checkbox."
  (let ((name (or (cdr (assq choice (widget-get widget :labels))) choice)))
    (if (widget-get widget :checkbox)
        (format " %s %s " (if (memq choice (widget-value widget)) "☑" "☐") name)
      (format " %s " name))))

(defun widgetry-chips--hover-key (widget)
  "The index of the chip of WIDGET under the pointer, or nil (also on its tag)."
  (when-let* ((column (widgetry-pointer-offset widget))
              ((>= column (length (widget-get widget :tag)))))
    (widgetry-chips--index widget column)))

(defface widgetry-check-on
  '((t (:inherit widgetry-button-fill-choice)))
  "Face whose background fills a ticked checkbox."
  :group 'widgetry)

(defun widgetry-chips--box (text on)
  "The box part of a checkbox chip, ON nil, t or `partial': TEXT (with ☐ ☑ or ⊟) in
a terminal, a drawn box centred in its cells in SVG."
  (let ((frame (widgetry--frame (current-buffer))))
    (list text 'default nil nil
          (list :box (pcase on ('nil 'off) ('partial 'partial) (_ 'on))
                :box-fill (car (widgetry--paint 'widgetry-check-on frame))
                :box-border (widgetry--blend (nth 1 (widgetry--paint 'widgetry-value frame))
                                             (car (widgetry--paint 'default frame)) 0.55)))))

(defun widgetry-chips--parts (widget)
  "The look of WIDGET: its tag, then a chip per choice, on ones lit; a checkbox
chip is its box, then its name."
  (cons (list (widget-get widget :tag) (widget-get widget :tag-face))
        (cl-loop with room = (widgetry-window-pixels widget)
                 with used = (string-pixel-width (widget-get widget :tag))
                 with cw = (frame-char-width)
                 for choice in (widget-get widget :choices)
                 for i from 0
                 for on = (memq choice (widget-value widget))
                 for box = (widget-get widget :checkbox)
                 for label = (widgetry-chips--label widget choice)
                 append (let ((parts (widgetry-hover-parts
                                      (cond ((not box)
                                             (list (list label (if on 'widgetry-value-on 'widgetry-value))))
                                            ;; A box alone (no name) takes the whole chip
                                            ((string-blank-p (substring label 3))
                                             (list (widgetry-chips--box label on)))
                                            (t (list (widgetry-chips--box (substring label 0 3) on)
                                                     (list (substring label 3)
                                                           (if on 'widgetry-value-on 'widgetry-value)))))
                                      (widgetry-hover-phase widget i))))
                          ;; A chip that would run past the window starts a new line
                          ;; (the divider cell becomes the newline: offsets stay).
                          (let* ((px (+ cw (string-pixel-width label)))
                                 (wrap (and room (> i 0) (> (+ used px) room))))
                            (setq used (if wrap (- px cw) (+ used px)))
                            (if (> i 0)
                                (cons (let ((part (widgetry-part-divided (car parts))))
                                        (if wrap
                                            (append (seq-take part 4) (list (append '(:break t) (nth 4 part))))
                                          part))
                                      (cdr parts))
                              parts))))))

(defun widgetry-chips--starts (widget)
  "Offsets of the start of each chip of WIDGET from the start of its text."
  (let ((offset (length (widget-get widget :tag))) starts)
    (dolist (choice (widget-get widget :choices))
      (push offset starts)
      (setq offset (+ offset (length (widgetry-chips--label widget choice)))))
    (nreverse starts)))

(defun widgetry-chips--index (widget offset)
  "Index of the chip of WIDGET at OFFSET into its text, the nearest if on the tag."
  (let ((index 0))
    (cl-loop for start in (widgetry-chips--starts widget)
             for i from 0
             when (<= start offset) do (setq index i))
    index))

(defun widgetry-chips--toggle (widget index)
  "Flip the chip at INDEX of WIDGET, as a change by the user."
  (let* ((choice (nth index (widget-get widget :choices)))
         (value (widget-value widget)))
    (unless (widget-get widget :disabled)
      (widgetry-notify
       widget (if (widget-get widget :single)
                  (unless (memq choice value) (list choice))
                (cl-remove-if-not
                 (lambda (c) (if (eq c choice) (not (memq c value)) (memq c value)))
                 (widget-get widget :choices))))
      (when-let* ((master (widget-get widget :master)))
        (widgetry-chips--sync-master master widget)))))

(defun widgetry-chips-toggle (&optional event)
  "Toggle the chip at point, or under the mouse EVENT."
  (interactive (list last-nonmenu-event))
  (let* ((widget (widgetry-widget-at event 'chips))
         (offset (if (mouse-event-p event)
                     (widgetry-click-offset widget event)
                   (- (point) (overlay-start (widget-get widget :widgetry-overlay))))))
    (widgetry-chips--toggle widget (widgetry-chips--index widget offset))))

(defun widgetry-chips--move (steps)
  "Move point STEPS chips along the widget at point, stopping at its ends."
  (let* ((widget (widgetry-widget-at nil 'chips))
         (start (overlay-start (widget-get widget :widgetry-overlay)))
         (starts (widgetry-chips--starts widget))
         (index (max 0 (min (1- (length starts))
                            (+ steps (widgetry-chips--index
                              widget (- (point) (overlay-start (widget-get widget :widgetry-overlay)))))))))
    (goto-char (+ start (nth index starts)))))

(defun widgetry-chips-next ()
  "Move point to the next chip."
  (interactive)
  (widgetry-chips--move 1))

(defun widgetry-chips-previous ()
  "Move point to the previous chip."
  (interactive)
  (widgetry-chips--move -1))

;;;; One checkbox

(define-widget 'widgetry-check 'widgetry-chips
  "One checkbox, the box of a `:checkbox' chips group alone: value (on) or nil.
Its chip is the hit area, the box padded to four columns.  With `:partial'
non-nil an unticked box shows a dash: a master box over a partly chosen group."
  :checkbox t
  :choices '(on)
  :labels '((on . ""))
  :partial nil
  :parts #'widgetry-check--parts
  :tag "")

(defun widgetry-check--parts (widget)
  "The look of the checkbox WIDGET: one box, ticked, dashed or empty."
  (let ((on (cond ((widget-value widget) t) ((widget-get widget :partial) 'partial))))
    (list (widgetry-chips--box (pcase on ('nil " ☐  ") ('partial " ⊟  ") (_ " ☑  ")) on))))

;;;; A master box over a chips group

(defun widgetry-chips-master-insert (chips)
  "Insert a master checkbox bound to the `:checkbox' CHIPS widget: empty, dashed
when some are chosen, ticked when all are; a press chooses all, or none when all
were."
  (let ((master (widget-create 'widgetry-check
                               :notify (lambda (w &rest _)
                                         (let ((all (widget-get chips :choices)))
                                           (widgetry-notify chips (unless (equal (widget-value chips) all)
                                                                    (copy-sequence all)))
                                           (widgetry-chips--sync-master w chips))))))
    (widget-put chips :master master)
    (widgetry-chips--sync-master master chips)
    master))

(defun widgetry-chips--sync-master (master chips)
  "Draw MASTER from the value of CHIPS."
  (let ((n (length (widget-value chips))) (m (length (widget-get chips :choices))))
    (widget-put master :partial (< 0 n m))
    (widgetry-set master (and (= n m) (> m 0) '(on)))))

(provide 'widgetry-chips)
;;; widgetry-chips.el ends here
