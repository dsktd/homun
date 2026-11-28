;;; widgetry-button.el --- A push button widget -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; A `widget' for an action: a tag (an icon or short label) and a value,
;; the label text, pressed by RET, SPC or a click.  It looks pressed for
;; a moment, then `:notify' runs.  Like a real button, pressing the mouse
;; on it and releasing it elsewhere cancels the press.
;;
;;   (widget-create 'widgetry-button :tag " ▶ " :value " Run "
;;                  :notify (lambda (&rest _) (message "run")))
;;
;; With `:confirm' `hold', the button is press-and-hold instead: a thin track
;; along the bottom of its label fills left to right over
;; `widgetry-button-hold-time', and it confirms on release once full.
;; With any other non-nil `:confirm', the button is slide-to-confirm: press it and
;; drag left, and it fills from the right in `:fill-face' (default the
;; red `widgetry-button-fill', for destructive actions), to the pixel;
;; once it arms the fill eases in to full over `widgetry-button-ease-time';
;; releasing after a full width (`widgetry-button-confirm-distance')
;; confirms and notifies, releasing earlier or dragging back cancels.  A
;; plain click only shows the hint "← drag" for
;; `widgetry-button-hint-time' seconds.  From the keyboard, where
;; holding is not possible, RET or SPC shows the hint, and pressing RET
;; or SPC again while it shows confirms.  With `:disabled'
;; non-nil, the button is dimmed and presses are ignored; `:disabled'
;; `hidden' draws it as blank space of the same width, so nothing moves.
;;
;; The button is drawn by an overlay (see `widgetry-insert'): every state
;; is the same size, and the buffer text never changes.

;;; Code:

(require 'widgetry-core)
(require 'cl-lib)

(defcustom widgetry-button-press-time 0.15
  "Seconds a button looks pressed."
  :type 'number
  :group 'widgetry)

(defcustom widgetry-button-hold-time 0.6
  "Seconds to hold a `:confirm hold' button to arm it."
  :type 'number
  :group 'widgetry)

(defcustom widgetry-button-confirm-distance nil
  "Pixels to drag a :confirm button to confirm it; nil for its own width."
  :type '(choice (const :tag "Width of the button" nil) natnum)
  :group 'widgetry)

(defcustom widgetry-button-ease-time 0.12
  "Seconds the fill of an armed :confirm button takes to reach full."
  :type 'number
  :group 'widgetry)

(defcustom widgetry-button-hint-time 1.5
  "Seconds a :confirm button shows its hint."
  :type 'number
  :group 'widgetry)

(defface widgetry-button-tag
  '((t (:inherit widgetry-tag)))
  "Face for the tag of a button."
  :group 'widgetry)

(defface widgetry-button-value
  '((t (:inherit widgetry-value)))
  "Face for the value of a button."
  :group 'widgetry)

(defface widgetry-button-pressed
  '((t ( :inherit widgetry-value
         :weight bold)))
  "Face for the value of a button while it is pressed."
  :group 'widgetry)

(defface widgetry-button-pressed-tag
  '((t ( :inherit widgetry-button-tag)))
  "Face for the tag of a button while it is pressed."
  :group 'widgetry)

(defface widgetry-button-fill
  '((t ( :inherit widgetry-value
         :weight bold)))
  "Face for the filled part of a :confirm button being dragged."
  :group 'widgetry)

(defface widgetry-button-fill-choice
  '((t ( :inherit widgetry-button-fill)))
  "A blue fill for :confirm buttons that choose rather than destroy."
  :group 'widgetry)

(defface widgetry-button-activated-tag
  '((t ( :inherit widgetry-button-tag)))
  "Face for the tag of a held `:confirm hold' button that releasing would confirm."
  :group 'widgetry)

(defface widgetry-button-armed-tag
  '((t ( :inherit widgetry-button-tag)))
  "Face for the tag of a :confirm button that releasing would confirm."
  :group 'widgetry)

(defface widgetry-button-disabled
  '((t ( :inherit widgetry-value)))
  "Face for the tag and value of a disabled button."
  :group 'widgetry)

(defface widgetry-button-done
  '((t ( :inherit widgetry-value)))
  "Face for the value of a button whose `:status' is `done'."
  :group 'widgetry)

(defface widgetry-button-done-tag
  '((t ( :inherit widgetry-button-tag)))
  "Face for the tag of a button whose `:status' is `done'."
  :group 'widgetry)

(defface widgetry-button-pending-tag
  '((t ( :inherit widgetry-button-tag)))
  "Face for the tag of a button whose `:status' is `pending'."
  :group 'widgetry)

(defface widgetry-button-failed-tag
  '((t ( :inherit widgetry-button-tag)))
  "Face for the tag of a button whose `:status' is `failed'."
  :group 'widgetry)

(defvar widgetry-button-map
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1] #'widgetry-button-drag)
    (define-key map (kbd "RET") #'widgetry-button-press)
    (define-key map (kbd "SPC") #'widgetry-button-press)
    map)
  "Keymap for button widgets.")

(define-widget 'widgetry-button 'item
  "A labelled push button."
  ;; Its parts light up on hover themselves.
  :hover-own t
  ;; Ask `y-or-n-p' before pressing.
  :confirm nil
  ;; Ignore presses and look dimmed.
  :disabled nil
  ;; What its action came to: nil, `pending', `done' or `failed'.  Its tag
  ;; shows it (a spinner, a check mark, a cross) and `done' tints the button;
  ;; a button without a tag gets the tint alone.
  :status nil
  ;; Non-nil while it looks pressed.
  :pressed nil
  ;; The hint timer of a :confirm button, while the hint shows.
  :hint nil
  ;; How much of a :confirm button is filled, 0.0 to 1.0, while dragged.
  :fill 0.0
  ;; The face of the fill of a :confirm button.
  :fill-face 'widgetry-button-fill
  ;; The timer easing the fill to full once armed, while it runs.
  :ease nil
  ;; Non-nil while a dragged :confirm button would confirm if released.
  :ready nil
  ;; A function of the widget giving the label to draw, nil for the value.
  :shown nil
  ;; The look of its kind; nil for `widgetry-button-style'.
  :style nil
  ;; The face of its label when idle; nil for `widgetry-button-value'.
  :label-face nil
  :keymap widgetry-button-map
  :widgetry-type '(button)
  :value-create #'widgetry-button--create
  :value-set #'widgetry-value-set
  :parts #'widgetry-button--parts
  :suppress-face t
  :tag nil
  :tag-face 'widgetry-button-tag
  :value " Button "
  :format "%v")

(defun widgetry-button--label (widget)
  "The text of the value of WIDGET: its hint while that shows."
  (let* ((label (format "%s" (if-let* ((shown (widget-get widget :shown)))
                                 (funcall shown widget)
                               (widget-value widget))))
         (width (string-width label)))
    (if (widget-get widget :hint)
        (truncate-string-to-width
         (concat (make-string (max 0 (/ (- width 6) 2)) ?\s) "← drag")
         width nil ?\s)
      label)))

(defun widgetry-button--armed-face (fill-face)
  "A face like `widgetry-button-armed-tag' on the background of FILL-FACE.
A named face, since the SVG drawing reads attributes of face symbols."
  (let ((face (intern (format "widgetry-button-armed-tag--%s" fill-face))))
    (unless (facep face)
      (make-face face)
      (set-face-attribute face nil :inherit 'widgetry-button-armed-tag
                          :background (face-background fill-face nil t)))
    face))

(defun widgetry-button--tag-face (disabled ready face &optional pressed fill-face status)
  "The face of the tag: dimmed if DISABLED, armed if READY, pressed, else FACE.
Armed, it takes the background of FILL-FACE, so tag and fill match.
STATUS `done' wins over all of these, `pending' and `failed' over FACE."
  (cond ((eq status 'done) 'widgetry-button-done-tag)
        (disabled 'widgetry-button-disabled)
        ((eq ready 'hold) 'widgetry-button-activated-tag)
        ((and ready fill-face (not (eq fill-face 'widgetry-button-fill)))
         (widgetry-button--armed-face fill-face))
        (ready 'widgetry-button-armed-tag)
        (pressed 'widgetry-button-pressed-tag)
        ((eq status 'pending) 'widgetry-button-pending-tag)
        ((eq status 'failed) 'widgetry-button-failed-tag)
        (t face)))

(defun widgetry-button--tag-mark (tag mark)
  "MARK centred in the width of TAG, so the button never changes size."
  (truncate-string-to-width
   (let ((pad (max 0 (- (string-width tag) (string-width mark)))))
     (concat (make-string (/ pad 2) ?\s) mark (make-string (- pad (/ pad 2)) ?\s)))
   (string-width tag) nil ?\s))

(defun widgetry-button--tag-text (widget)
  "The tag of WIDGET; once armed, `:armed-tag' (default a check mark), else
the mark of its `:status' (a spinner, a check mark or a cross), in the tag's
width.  A button without a tag shows no mark."
  (let ((tag (widget-get widget :tag)))
    (cond ((not (stringp tag)) tag)
          ((widget-get widget :ready)
           (widgetry-button--tag-mark tag (or (widget-get widget :armed-tag) "✓")))
          (t (pcase (widget-get widget :status)
               ('pending (widgetry-button--tag-mark tag (widgetry-spinner-frame)))
               ('done (widgetry-button--tag-mark tag "✓"))
               ('failed (widgetry-button--tag-mark tag "✗"))
               (_ tag))))))

(defcustom widgetry-button-style (quote motion)
  "How a drag button (`:confirm' t) shows what it is.
Default `motion': on hover its fill slides in from the right and back out.
nil is the plain look.  A button's own `:style' overrides this."
  :type '(choice (const :tag "Plain" nil) (const motion))
  :group 'widgetry)

(defun widgetry-button--kind (widget)
  "The kind of WIDGET: `press', `drag' or `hold'."
  (pcase (widget-get widget :confirm)
    ('nil 'press)
    ('hold 'hold)
    (_ 'drag)))

(defun widgetry-button--style (widget)
  "The style WIDGET is drawn in."
  (or (widget-get widget :style) widgetry-button-style))

(defun widgetry-button--parts (widget)
  "The look of WIDGET: its tag, and its label filled as far as dragged,
in the kind's look of its style (see `widgetry-button-style')."
  (let* ((disabled (widget-get widget :disabled))
         (style (widgetry-button--style widget))
         (kind (widgetry-button--kind widget))
         (ready (widget-get widget :ready))
         (status (widget-get widget :status))
         ;; A :confirm button shows its press by the fill alone, in one colour.
         (pressed (and (widget-get widget :pressed) (eq kind 'press)))
         (fill (if disabled 0.0 (widget-get widget :fill)))
         (fill-face (widget-get widget :fill-face))
         (tag (widgetry-button--tag-text widget))
         (tag-face (widgetry-button--tag-face
                    disabled ready
                    (widget-get widget :tag-face) pressed fill-face status))
         (face (cond ((eq disabled 'hidden) 'default)
                     ;; The tint of a done button survives disabling.
                     ((eq status 'done) 'widgetry-button-done)
                     (disabled 'widgetry-button-disabled)
                     (pressed 'widgetry-button-pressed)
                     (t (or (widget-get widget :label-face) 'widgetry-button-value))))
         (deco nil))
    ;; A drag button slides its fill in and back out again over the hover.
    (when (and (eq style 'motion) (eq kind 'drag) (= fill 0))
      (let ((phase (or (widget-get widget :motion) 0.0)))
        (when (> phase 0)
          (setq fill (- (* 0.3 (sin (* float-pi phase))))))))
    ;; A hold button has a thin track along its bottom edge that fills as it
    ;; is held; a terminal cannot draw it, so there it fills the label.
    (when (and (eq kind 'hold) (not disabled))
      (let ((progress (or (car (widget-get widget :glow)) 0.0))
            (colour (or (and (facep fill-face) (face-background fill-face nil t))
                        (widgetry-theme-colour 'error))))
        (if (widgetry-graphic-p (widgetry--frame (current-buffer)))
            (setq deco (list :track progress :track-color colour))
          (setq fill (- progress)))))
    ;; Armed or firing: an outline in the button's own fill colour, inside
    ;; the button, so nothing moves.
    (when (and (not disabled) (or ready pressed))
      (setq deco (append (list :border 'solid
                               :border-color (or (and (facep fill-face)
                                                      (face-background fill-face nil t))
                                                 (widgetry-theme-colour 'shadow)))
                         deco)))
    (widgetry-hover-parts
     (append
     ;; The tag takes only the image-wide decorations of DECO; a `:bare'
     ;; button (an icon alone) has none.
     (when (and tag (not (widget-get widget :bare)))
      (list (list tag tag-face nil nil
                  (cl-loop for (k v) on deco by #'cddr
                           when (memq k '(:border :border-color))
                           append (list k v)))))
     (list (list (if (eq disabled 'hidden)
                     (make-string (string-width (widgetry-button--label widget)) ?\s)
                   (widgetry-button--label widget))
                 face fill fill-face deco)))
     (if disabled 0.0
       (widgetry-hover-phase (or (widget-get widget :group) widget)
                             (if (widget-get widget :group) widget t))))))

(defun widgetry-button--create (widget)
  "Insert WIDGET; the pointer lights it, and slides a drag button's hint."
  (widgetry-insert widget)
  (when-let* ((overlay (widget-get widget :widgetry-overlay)))
    (overlay-put overlay 'help-echo
                 (lambda (&rest _)
                   (widgetry-hover-enter widget)
                   (widgetry-button--hover widget)
                   nil))))

(defcustom widgetry-button-motion-time 0.4
  "Seconds of the slide a drag button shows as the pointer enters it."
  :type 'number
  :group 'widgetry)

(defun widgetry-button--hover (widget)
  "Run the slide hint on WIDGET, if it is a drag button in the `motion' style.
Called as the pointer moves over it; a running animation is left alone,
so it costs a timer only while it plays."
  (when (and (eq (widgetry-button--style widget) 'motion)
             (eq (widgetry-button--kind widget) 'drag)
             (not (widget-get widget :motion-timer))
             (not widgetry-active-gesture))
    (let ((start (float-time))
          (span widgetry-button-motion-time))
      (widget-put widget :motion-timer
                  (run-with-timer
                   0 0.04
                   (lambda ()
                     (let ((phase (/ (- (float-time) start) span)))
                       (when (or (>= phase 1.0) widgetry-active-gesture)
                         (cancel-timer (widget-get widget :motion-timer))
                         (widget-put widget :motion-timer nil)
                         (setq phase 0.0))
                       (widget-put widget :motion phase)
                       (widgetry-redraw widget))))))))

(defun widgetry-button--ease-stop (widget)
  "Stop easing the fill of WIDGET."
  (when-let* ((timer (widget-get widget :ease)))
    (cancel-timer timer)
    (widget-put widget :ease nil)))

(defun widgetry-button--ease (widget)
  "Ease the fill of WIDGET from where it is to full in `widgetry-button-ease-time'."
  (widgetry-button--ease-stop widget)
  (let ((from (widget-get widget :fill))
        (start (float-time)))
    (widget-put widget :ease
                (run-with-timer
                 0 0.02
                 (lambda ()
                   (let* ((tt (min 1.0 (/ (- (float-time) start)
                                          (max 0.001 widgetry-button-ease-time))))
                          (eased (- 1 (expt (- 1 tt) 3))))
                     (widget-put widget :fill (+ from (* eased (- (if (< from 0) -1.0 1.0) from))))
                     (when (>= tt 1.0) (widgetry-button--ease-stop widget))
                     (widgetry-redraw widget)))))))

(defun widgetry-button--arm (widget ready fill)
  "Set WIDGET to READY with FILL; on arming, ease the fill in to full."
  (cond ((and ready (not (widget-get widget :ready)))
         (widgetry-button--ease widget))
        ((not ready)
         (widgetry-button--ease-stop widget)
         (widget-put widget :fill fill)))
  (widget-put widget :ready ready))

(defun widgetry-button--fill (distance width &optional lead)
  "The fraction, 0.0 to 1.0, of a button of WIDTH pixels filled by DISTANCE pixels.
The fill is complete LEAD pixels (one character by default) before the
confirm point, so the full fill shows before the tag turns armed."
  (let ((span (max 1 (- (or widgetry-button-confirm-distance width)
                        (or lead (frame-char-width))))))
    (max 0.0 (min 1.0 (/ (float distance) span)))))

(defun widgetry-button--confirmed-p (distance width)
  "Non-nil if dragging DISTANCE pixels confirms a button of WIDTH pixels."
  (>= distance (or widgetry-button-confirm-distance width)))

(defun widgetry-button--width (widget)
  "The drag length of WIDGET in pixels: its value's full width, so the fill's
edge stays under the pointer."
  (* (string-width (format "%s" (widget-value widget))) (frame-char-width)))

(defun widgetry-button--redraw (widget)
  "Draw WIDGET again."
  (widgetry-redraw widget))

(defun widgetry-button--hit-p (position widget)
  "Non-nil if buffer POSITION is on the text of WIDGET."
  (and (integerp position)
       (<= (widget-get widget :from) position)
       (< position (widget-get widget :to))))

(defun widgetry-button--over-p (event widget)
  "Non-nil if the mouse EVENT is over WIDGET.
A widget drawn as part of a bigger image has an `:over-function', called
with WIDGET and EVENT; otherwise the buffer position decides."
  (if-let* ((over (widget-get widget :over-function)))
      (funcall over widget event)
    (widgetry-button--hit-p (widgetry-button--event-position event) widget)))

(defun widgetry-button--release (widget)
  "Look pressed for `widgetry-button-press-time', then normal again."
  (widget-put widget :pressed nil)
  (widgetry-button--redraw widget))

(defun widgetry-button--hint-end (widget)
  "Stop showing the hint of WIDGET."
  (when-let* ((timer (widget-get widget :hint)))
    (cancel-timer timer)
    (widget-put widget :hint nil)
    (widgetry-button--redraw widget)))

(defun widgetry-button--hint (widget)
  "Show the hint on WIDGET for `widgetry-button-hint-time'."
  (widget-put widget :hint
              (run-with-timer widgetry-button-hint-time nil
                              #'widgetry-button--hint-end widget))
  (widgetry-button--redraw widget))

(defun widgetry-button--press (widget)
  "Press WIDGET from the keyboard or a click.
A :confirm button shows its hint first, and presses if it shows already.
Return non-nil if it was pressed."
  (unless (widget-get widget :disabled)
    (cond ((not (widget-get widget :confirm))
           (widgetry-button--do-press widget)
           t)
          ((widget-get widget :hint)
           (widgetry-button--hint-end widget)
           (widgetry-button--do-press widget)
           t)
          (t (widgetry-button--hint widget)
             nil))))

(defun widgetry-button--do-press (widget)
  "Look pressed, then tell the `:notify' of WIDGET."
  (widget-put widget :pressed t)
  (widgetry-flash widget)
  (run-with-timer widgetry-button-press-time nil #'widgetry-button--release widget)
  (widget-apply widget :notify widget))

(defun widgetry-button-press (&optional event)
  "Press the button at point, or under the mouse EVENT.
A :confirm button shows a hint; pressing again within
`widgetry-button-hint-time' confirms it."
  (interactive (list last-nonmenu-event))
  (widgetry-button--press (widgetry-widget-at event 'button)))

(defun widgetry-button--event-position (event)
  "The buffer position under the mouse EVENT, or nil."
  (and (mouse-event-p event)
       (posn-point (event-end event))))

(defun widgetry-button--event-x (event)
  "The x pixel of the mouse EVENT in its window, or nil."
  (and (mouse-event-p event)
       (car-safe (posn-x-y (event-end event)))))

(defun widgetry-button--hold (widget)
  "Fill WIDGET while the mouse is held; return non-nil if released armed.
Moving off the button cancels."
  (let ((start (float-time))
        (armed nil)
        (off nil)
        (widgetry-active-gesture widget))
    (setq cursor-type nil)
    (unwind-protect
        (track-mouse
          (while (let ((next (widgetry-read-event 0.02)))
                   (cond ((null next)
                          (let ((fill (min 1.0 (/ (- (float-time) start)
                                                  (max 0.01 widgetry-button-hold-time)))))
                            (unless off
                              (setq armed (>= fill 1.0))
                              (widget-put widget :glow (cons (if armed 1.0 fill) (- (float-time) start)))
                              (widget-put widget :ready (and armed 'hold))
                              (widgetry-button--redraw widget)))
                          t)
                         ((eq (car-safe next) 'mouse-movement)
                          (unless (widgetry-button--over-p next widget)
                            (setq off t armed nil))
                          t)
                         ((and (mouse-event-p next) (memq 'down (event-modifiers next))) t)
                         ((mouse-event-p next) nil)
                         ((memq (car-safe next) '(switch-frame select-window help-echo
                                                  focus-in focus-out))
                          t)
                         (t nil)))))
      (setq cursor-type t)
      (widget-put widget :fill 0.0)
      (widget-put widget :glow nil)
      (widget-put widget :ready nil))
    armed))

(defun widgetry-button-drag (event &optional widget)
  "Follow the mouse pressed on the button under EVENT.
Releasing it on the button presses it; releasing elsewhere cancels.  On a
:confirm button, drag left to fill it, and release full to confirm; a
click only shows the hint.  WIDGET is the button, by default the one
under EVENT."
  (interactive "e")
  (let ((widget (or widget (widgetry-widget-at event 'button))))
    (if (eq (widget-get widget :confirm) 'hold)
        (if (and (widgetry-button--hold widget) (not (widget-get widget :disabled)))
            (widgetry-button--do-press widget)
          (widgetry-button--redraw widget))
      (widgetry-button--drag-confirm event widget))))

(defun widgetry-button--drag-confirm (event widget)
  "Follow a drag on the button WIDGET pressed by EVENT; see `widgetry-button-drag'."
  (let* ((confirm (widget-get widget :confirm))
         (width (widgetry-button--width widget))
         (start (widgetry-button--event-x event))
         (last event)
         (release nil)
         (moved nil)
         (armed nil)
         (widgetry-active-gesture widget))
    (setq cursor-type nil)
    (unwind-protect
        (track-mouse
          (while (let ((next (widgetry-read-event)))
                   (cond ((eq (car-safe next) 'mouse-movement)
                          (setq last next)
                          (when (and confirm start (widgetry-button--event-x next))
                            (setq moved t)
                            ;; Drag left, toward the tag: the fill grows from the right.
                            (let ((distance (- start (widgetry-button--event-x next))))
                              (setq armed (widgetry-button--confirmed-p distance width))
                              (widgetry-button--arm
                               widget (widgetry-button--confirmed-p distance width)
                               (- (widgetry-button--fill distance width 0))))
                            (widgetry-button--redraw widget))
                          t)
                         ;; Only a button release ends the drag; focus,
                         ;; help-echo and other events in between do not.
                         ((and (mouse-event-p next)
                               (memq 'down (event-modifiers next)))
                          t)
                         ((mouse-event-p next) (setq release next) nil)
                         ((memq (car-safe next) '(switch-frame select-window help-echo
                                                  focus-in focus-out))
                          t)
                         (t (setq release next) nil)))))
      (setq cursor-type t))
    (let* ((end (if (mouse-event-p release) release last))
           (x (widgetry-button--event-x end)))
      (cond ((not confirm)
             (when (widgetry-button--over-p end widget)
               (widgetry-button--press widget)))
            (t
             (widgetry-button--arm widget nil 0.0)
             ;; Armed by the last movement confirms, even if the release
             ;; lands outside the window, where it has no x.
             (if (and moved start (not (widget-get widget :disabled))
                      (if x (widgetry-button--confirmed-p (- start x) width) armed))
                 (widgetry-button--do-press widget)
               (widgetry-button--redraw widget)
               (when (and (not moved) (not (widget-get widget :disabled))
                          (widgetry-button--over-p end widget))
                 (widgetry-button--hint widget))))))))

(provide 'widgetry-button)
;;; widgetry-button.el ends here
