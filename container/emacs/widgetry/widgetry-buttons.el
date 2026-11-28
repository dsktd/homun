;;; widgetry-buttons.el --- A row of touching buttons -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; A `widget' for related buttons drawn as one row, touching, in one image
;; like `widgetry-chips'.  Each segment is a `widgetry-button' of its own,
;; with an optional :tag, hover, hold track and activation
;; flash; :buttons lists them as plists of a :label and any button
;; keyword (:notify, :confirm, :disabled ...).  RET or SPC presses the
;; segment at point; h and l (or left and right) move between segments.
;;
;;   (widget-create 'widgetry-buttons
;;                  :buttons '((:label "Compact" :confirm hold
;;                              :notify (lambda (&rest _) (message "compact")))
;;                             (:label "Settings"
;;                              :notify (lambda (&rest _) (message "settings")))))
;;
;; A flash or an armed outline surrounds the whole row, since the row is
;; one image.

;;; Code:

(require 'cl-lib)
(require 'widgetry-core)
(require 'widgetry-button)

(defvar widgetry-buttons-map
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1] #'widgetry-buttons-drag)
    (define-key map (kbd "RET") #'widgetry-buttons-press)
    (define-key map (kbd "SPC") #'widgetry-buttons-press)
    (dolist (key (list "h" [left]))
      (define-key map key #'widgetry-buttons-previous))
    (dolist (key (list "l" [right]))
      (define-key map key #'widgetry-buttons-next))
    map)
  "Keymap for button groups.")

(define-widget 'widgetry-buttons-segment 'widgetry-button
  "One button of a `widgetry-buttons' row, drawn as part of the row."
  ;; The row it belongs to.
  :group nil
  :parts (lambda (segment)
           (widgetry-buttons--parts (widget-get segment :group)))
  :over-function #'widgetry-buttons--over-p)

(define-widget 'widgetry-buttons 'item
  "A row of touching buttons."
  :reflow t
  :buttons nil
  ;; Non-nil: in a terminal, the row fills the window width.
  :stretch nil
  ;; The segment widgets, made on creation.
  :segments nil
  :keymap widgetry-buttons-map
  :hover-own t
  :hover-key #'widgetry-buttons--hover-key
  :widgetry-type '(buttons)
  :value-create #'widgetry-buttons--create
  :value-set #'widgetry-value-set
  :parts #'widgetry-buttons--parts
  :suppress-face t
  :format "%v")

(defun widgetry-buttons--segment (group spec)
  "A segment widget of GROUP from its SPEC, a plist with :label."
  (let ((args (copy-sequence spec)))
    (apply #'widget-convert 'widgetry-buttons-segment
           :group group
           :value (format " %s " (plist-get args :label))
           (cl-loop for (k v) on args by #'cddr
                    unless (eq k :label) append (list k v)))))

(defun widgetry-buttons--text-window (group)
  "The window showing GROUP when it is drawn as text cells, else nil."
  (let* ((overlay (widget-get group :widgetry-overlay))
         (window (and overlay (overlay-buffer overlay)
                      (get-buffer-window (overlay-buffer overlay) t))))
    (and window (not (widgetry-graphic-p (window-frame window))) window)))

(defun widgetry-buttons--segment-pixels (segment)
  "Pixels SEGMENT is drawn wide: its cells as `widgetry-cells' makes them, so the
padding and boxes of a touch screen count (cells alone undercount them)."
  (string-pixel-width (widgetry-cells (widgetry-button--parts segment))
                      (current-buffer)))

(defun widgetry-buttons--room (group window)
  "Pixels left in WINDOW after the segments of GROUP side by side, a gap cell
between them and a two cell margin included; negative when they do not fit.
Pixels, not cells: a window's width changes with rotation, the keyboard and
split screen, and a cell is wider than its character on a touch screen."
  (let ((cw (frame-char-width (window-frame window)))
        (segments (widget-get group :segments)))
    (with-current-buffer (overlay-buffer (widget-get group :widgetry-overlay))
      (- (window-body-width window t) (* cw (+ 2 (1- (length segments))))
         (cl-loop for s in segments sum (widgetry-buttons--segment-pixels s))))))

(defun widgetry-buttons-measure (window)
  "Plist of the numbers that decide the button layout in WINDOW, for the first
stretched group of its buffer: columns, pixels, char width, group room."
  (with-current-buffer (window-buffer window)
    (let ((group (cl-loop for o in (overlays-in (point-min) (point-max))
                          for w = (overlay-get o 'button)
                          when (and w (eq (widget-type w) 'widgetry-buttons) (widget-get w :stretch))
                          return w)))
      (list :cols (window-body-width window) :px (window-body-width window t)
            :cw (frame-char-width (window-frame window))
            :room (and group (widgetry-buttons--room group window))
            :segment-px (and group (mapcar #'widgetry-buttons--segment-pixels
                                           (widget-get group :segments)))))))

(defun widgetry-buttons--stacked-p (group)
  "Non-nil when GROUP, drawn as text, is too wide for its window in one row:
it then shows one segment per line, each the width of the window."
  (when-let* (((widget-get group :stretch))
              (window (widgetry-buttons--text-window group)))
    (< (widgetry-buttons--room group window) 0)))

(defun widgetry-buttons--segment-parts (group segment)
  "The parts of SEGMENT of GROUP; with :stretch in a terminal, its label padded
so the row fills the window and every segment is a wide touch target.  A group
too wide for one row (see `widgetry-buttons--stacked-p') pads every segment to
the window width instead."
  (let* ((parts (widgetry-button--parts segment))
         (window (and (widget-get group :stretch)
                      (widgetry-buttons--text-window group))))
    (if (not window)
        parts
      (let* ((segments (widget-get group :segments))
             (cw (frame-char-width (window-frame window)))
             (room (widgetry-buttons--room group window))
             (pad (if (< room 0)
                      (max 0 (/ (- (window-body-width window t) (* 2 cw)
                                   (widgetry-buttons--segment-pixels segment))
                                cw))
                    (let ((cells (/ room cw)))
                      (+ (/ cells (length segments))
                         (if (eq segment (car (last segments))) (% cells (length segments)) 0)))))
             (label (car (last parts))))
        (append (butlast parts)
                (list (cons (concat (car label) (make-string pad ?\s)) (cdr label))))))))

(defun widgetry-buttons--parts (group)
  "The look of GROUP: the parts of each segment in turn."
  (let ((stacked (widgetry-buttons--stacked-p group)))
    (cl-loop for segment in (widget-get group :segments)
             for first = t then nil
             for parts = (widgetry-buttons--segment-parts group segment)
             append (if first parts
                      (cons (let ((part (widgetry-part-divided (car parts))))
                              (if stacked
                                  (append (seq-take part 4)
                                          (list (append '(:break t) (nth 4 part))))
                                part))
                            (cdr parts))))))

(defun widgetry-buttons--widths (group)
  "The characters each segment of GROUP shows."
  (let ((gap (if (widgetry-graphic-p (widgetry--frame (current-buffer))) 0 1)))
    (cl-loop for segment in (widget-get group :segments)
             for first = t then nil
             collect (+ (if first 0 gap)
                        (cl-loop for part in (widgetry-buttons--segment-parts group segment)
                                 sum (length (car part)))))))

(defun widgetry-buttons--index (group offset)
  "Index of the segment of GROUP at OFFSET into its text."
  (let ((end 0) (index 0))
    (cl-loop for width in (widgetry-buttons--widths group)
             for i from 0
             do (setq end (+ end width))
             when (< offset end) return (setq index i)
             finally (setq index (max 0 (1- (length (widget-get group :segments))))))
    index))

(defun widgetry-buttons--segment-at (group offset)
  "The segment of GROUP at OFFSET into its text."
  (nth (widgetry-buttons--index group offset) (widget-get group :segments)))

(defun widgetry-buttons--event-segment (group event)
  "The segment of GROUP under the mouse EVENT, or nil if it is not over GROUP."
  (let ((object (posn-object (event-start event))))
    (when (consp object)
      (widgetry-buttons--segment-at group (widgetry-click-offset group event)))))

(defun widgetry-buttons--over-p (segment event)
  "Non-nil if the mouse EVENT is over SEGMENT."
  (eq segment (ignore-errors
                (widgetry-buttons--event-segment (widget-get segment :group) event))))

(defun widgetry-buttons--point-offset (group)
  "Offset of point into the text of GROUP."
  (- (point) (overlay-start (widget-get group :widgetry-overlay))))

(defun widgetry-buttons--pointer-segment (group)
  "The segment of GROUP under the mouse pointer, from its pixel position."
  (let* ((overlay (widget-get group :widgetry-overlay))
         (window (get-buffer-window (overlay-buffer overlay)))
         (pointer (mouse-pixel-position))
         (start (and window (posn-at-point (overlay-start overlay) window))))
    (when (and start (eq (car pointer) (window-frame window)) (cadr pointer))
      (let ((column (floor (- (cadr pointer)
                              (car (window-inside-pixel-edges window))
                              (car (posn-x-y start)))
                           (frame-char-width (car pointer)))))
        (cl-loop for segment in (widget-get group :segments)
                 for width in (mapcar (lambda (w) (widgetry--cells (make-string w ?x) nil))
                                      (widgetry-buttons--widths group))
                 do (setq column (- column width))
                 when (< column 0) return segment)))))

(defun widgetry-buttons--hover-key (group)
  "The segment of GROUP under the pointer, or nil."
  (and (widgetry-pointer-offset group)
       (ignore-errors (widgetry-buttons--pointer-segment group))))

(defun widgetry-buttons--create (group)
  "Insert GROUP, and make the `motion' style of its segments follow the pointer."
  (widget-put group :segments
              (mapcar (lambda (spec) (widgetry-buttons--segment group spec))
                      (widget-get group :buttons)))
  (widgetry-insert group)
  (when-let* ((overlay (widget-get group :widgetry-overlay)))
    (dolist (segment (widget-get group :segments))
      (widget-put segment :widgetry-overlay overlay))
    (overlay-put overlay 'help-echo
                 (lambda (&rest _)
                   (widgetry-hover-enter group)
                   (when-let* ((segment (ignore-errors (widgetry-buttons--pointer-segment group))))
                     (widgetry-button--hover segment))
                   nil))))

(defun widgetry-buttons-segment-at (&optional event)
  "The segment at point, or under the mouse EVENT."
  (let* ((group (widgetry-widget-at event 'buttons)))
    (widgetry-buttons--segment-at
     group (if (mouse-event-p event)
               (widgetry-click-offset group event)
             (widgetry-buttons--point-offset group)))))

(defun widgetry-buttons-press (&optional event)
  "Press the segment at point, or under the mouse EVENT."
  (interactive (list last-nonmenu-event))
  (widgetry-button--press (widgetry-buttons-segment-at event)))

(defun widgetry-buttons-drag (event)
  "Follow the mouse pressed on the segment under EVENT, as a button does."
  (interactive "e")
  (widgetry-button-drag event (widgetry-buttons-segment-at event)))

(defun widgetry-buttons--move (steps)
  "Move point STEPS segments along the group at point, stopping at its ends."
  (let* ((group (widgetry-widget-at nil 'buttons))
         (widths (widgetry-buttons--widths group))
         (index (max 0 (min (1- (length widths))
                            (+ steps (widgetry-buttons--index
                                      group (widgetry-buttons--point-offset group)))))))
    (goto-char (+ (overlay-start (widget-get group :widgetry-overlay))
                  (apply #'+ (seq-take widths index))))))

(defun widgetry-buttons-next ()
  "Move point to the next segment."
  (interactive)
  (widgetry-buttons--move 1))

(defun widgetry-buttons-previous ()
  "Move point to the previous segment."
  (interactive)
  (widgetry-buttons--move -1))

(defun widgetry-buttons-width (group)
  "Cells the image of GROUP takes in the frame showing this buffer."
  (let ((frame (widgetry--frame (current-buffer))))
    (apply #'+ (mapcar (lambda (p)
                         (+ (widgetry--cells (car p) frame)
                            (if (and (plist-get (nth 4 p) :divider) (not (widgetry-graphic-p frame))) 1 0)))
                       (widgetry-buttons--parts group)))))

(provide 'widgetry-buttons)
;;; widgetry-buttons.el ends here
