;;; widgetry-core.el --- Shared parts of the widgetry widgets -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; What every widgetry widget shares: the group, the tag and value
;; faces, the drawing by an overlay (SVG or block glyphs), dragging, and
;; `widgetry-mode' for the buffers the widgets live in.

;;; Code:

(require 'wid-edit)
(require 'svg)
(require 'homun-clock)
(declare-function font-info "font.c")

(defgroup widgetry nil
  "Widgets for interactive buffers."
  :group 'widgets)

(defface widgetry-tag
  '((t (:inherit secondary-selection :box t)))
  "Face for the tag of a widget.")

(defface widgetry-value
  '((t (:inherit highlight :box t)))
  "Face for the value of a widget.")

(defface widgetry-value-on
  '((t (:inherit (success widgetry-value) :weight bold :inverse-video t)))
  "Face for the value of a widget that is on.")

;;;; Theme colours

(defun widgetry-theme-colour (face &optional attribute frame)
  "ATTRIBUTE (default :foreground) of FACE on FRAME as #RRGGBB.
Falls back to the default face's foreground when FACE has none."
  (or (widgetry--color (widgetry--face-attribute face (or attribute :foreground) frame) frame nil)
      (widgetry--color (widgetry--face-attribute 'default :foreground frame) frame "#CBCBCB")))

(defun widgetry--theme-specs ()
  "Alist of (FACE . ATTRIBUTES): the fills and tints computed from the active theme.
The colours are the theme's `success', `warning', `error' and `link' foregrounds and
blends of its default background and foreground."
  (let* ((fg (widgetry-theme-colour 'default))
         (bg (widgetry-theme-colour 'default :background))
         (ok (widgetry-theme-colour 'success)) (warn (widgetry-theme-colour 'warning))
         (err (widgetry-theme-colour 'error)) (blue (widgetry-theme-colour 'link))
         (tint (lambda (n) (widgetry--blend bg fg n)))
         (on (lambda (c &rest more) `(:background ,c :foreground ,bg ,@more))))
    `((widgetry-tag :background ,(funcall tint 0.2) :foreground ,fg :box t)
      (widgetry-value :background ,(funcall tint 0.12) :foreground ,fg :box t)
      (widgetry-value-on :inherit widgetry-value :weight bold ,@(funcall on ok))
      (widgetry-sign :inherit widgetry-value :background ,(funcall tint 0.16))
      (widgetry-button-pressed :inherit widgetry-value :weight bold ,@(funcall on warn))
      (widgetry-button-pressed-tag :inherit widgetry-button-tag ,@(funcall on warn))
      (widgetry-button-fill :inherit widgetry-value :weight bold ,@(funcall on err))
      (widgetry-button-fill-choice :inherit widgetry-button-fill :background ,blue)
      (widgetry-button-activated-tag :inherit widgetry-button-tag ,@(funcall on ok))
      (widgetry-button-armed-tag :inherit widgetry-button-tag ,@(funcall on err))
      (widgetry-button-disabled :inherit widgetry-value :foreground ,(widgetry--blend fg bg 0.5))
      (widgetry-button-done :inherit widgetry-value ,@(funcall on ok))
      (widgetry-button-done-tag :inherit widgetry-button-tag ,@(funcall on ok))
      (widgetry-button-pending-tag :inherit widgetry-button-tag :foreground ,warn)
      (widgetry-button-failed-tag :inherit widgetry-button-tag :foreground ,err)
      (widgetry-meter-fill :inherit widgetry-slider-value :background ,blue)
      (widgetry-meter-fill-ok :inherit widgetry-meter-fill :background ,ok)
      (widgetry-meter-fill-warn :inherit widgetry-meter-fill :background ,warn)
      (widgetry-meter-fill-high :inherit widgetry-meter-fill :background ,err)
      (widgetry-slider-x :inherit widgetry-slider-tag :weight bold ,@(funcall on err))
      (widgetry-slider-y :inherit widgetry-slider-tag :weight bold ,@(funcall on ok))
      (widgetry-slider-z :inherit widgetry-slider-tag :weight bold ,@(funcall on blue))
      (widgetry-selector-value-alt :inherit widgetry-value :background ,blue)
      (widgetry-toggle-on-tag :inherit widgetry-toggle-tag ,@(funcall on ok)))))

(defun widgetry-theme-apply ()
  "Set the widget faces from the active theme: run at load and by `enable-theme-functions'.
They sit in the defface layer, so a customization or a theme still wins."
  (pcase-dolist (`(,face . ,spec) (widgetry--theme-specs))
    (when (facep face)
      (face-spec-set face (list (list t spec)) 'face-defface-spec))))

(add-hook 'enable-theme-functions (lambda (&rest _) (widgetry-theme-apply)))
(add-hook 'disable-theme-functions (lambda (&rest _) (widgetry-theme-apply)))

;;;; Status

(defface widgetry-status-done '((t (:inherit success)))
  "Face for something that finished well.")

(defface widgetry-status-pending '((t (:inherit warning)))
  "Face for something still under way.")

(defface widgetry-status-failed '((t (:inherit error)))
  "Face for something that failed.")

(defface widgetry-status-stopped '((t (:inherit shadow)))
  "Face for something that was stopped.")

(defconst widgetry-spinner-frames ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "The frames of the spinner, in order.")

(defconst widgetry-spinner-interval 0.12
  "Seconds one frame of the spinner shows.")

(defun widgetry-spinner-frame ()
  "The frame of the spinner to show now."
  (aref widgetry-spinner-frames
        (mod (floor (float-time) widgetry-spinner-interval)
             (length widgetry-spinner-frames))))

(defvar widgetry--spinning nil
  "Widgets drawn again every spinner frame while their `:status' is `pending'.")

(defvar widgetry--spin-frame nil "The spinner frame last drawn.")

(defun widgetry--spin-target (widget)
  "The widget drawn for WIDGET: its group, else itself."
  (or (widget-get widget :group) widget))

(defun widgetry--spin-tick (&optional _snap)
  "Redraw the spinning widgets when the frame changed; forget the ones done or
gone.
Return non-nil while any is left, so the clock goes on."
  (setq widgetry--spinning
        (seq-filter (lambda (widget)
                      (and (eq (widget-get widget :status) 'pending)
                           (when-let* ((overlay (widget-get (widgetry--spin-target widget)
                                                            :widgetry-overlay)))
                             (overlay-buffer overlay))))
                    widgetry--spinning))
  (let ((frame (floor (float-time) widgetry-spinner-interval)))
    (unless (eql frame widgetry--spin-frame)
      (setq widgetry--spin-frame frame)
      (dolist (target (delete-dups (mapcar #'widgetry--spin-target widgetry--spinning)))
        (ignore-errors (widgetry-redraw target)))))
  (and widgetry--spinning t))

(defun widgetry-spin (widget)
  "Keep the spinner of WIDGET turning while its `:status' is `pending'.
It turns on `homun-clock', which has the only timer."
  (cl-pushnew widget widgetry--spinning)
  (homun-clock-register 'widgetry-spin #'widgetry--spin-tick))

(defun widgetry-widget-at (event type)
  "The widget of TYPE under EVENT (or at point if EVENT is not a mouse event).
Point does not move.
TYPE is the symbol of a widgetry widget; subtypes of it count."
  ;; Find the widget under the mouse without moving point, so point stays
  ;; where the user left it while a widget is used.
  (let ((widget (if (mouse-event-p event)
                    (let ((posn (event-start event)))
                      (with-current-buffer (window-buffer (posn-window posn))
                        (and (integerp (posn-point posn)) (widget-at (posn-point posn)))))
                  (widget-at))))
    (unless (and widget (widget-type widget)
                 (widget-get widget :widgetry-type)
                 (memq type (widget-get widget :widgetry-type)))
      (user-error "No %s here" type))
    widget))

(defun widgetry-set (widget value)
  "Set WIDGET to VALUE and redraw it."
  (widget-value-set widget value))

(defun widgetry-notify (widget value)
  "Set WIDGET to VALUE as a change by the user, and tell its `:notify'."
  (widgetry-set widget value)
  (widgetry-flash widget)
  (widget-apply widget :notify widget))

(defun widgetry-fill-split (fraction length)
  "How many of LENGTH characters FRACTION (0.0 to 1.0) fills."
  (max 0 (min length (round (* fraction length)))))

(defconst widgetry-eighths " ▏▎▍▌▋▊▉"
  "Block glyphs filling 0 to 7 eighths of a cell from the left.")

(defun widgetry-cell-filled-text (text fraction fill-face face)
  "TEXT with FRACTION of it in FILL-FACE and the rest in FACE, by cells.
For a terminal frame: a space at the edge shows the eighth block it
reaches, in the colour of the fill on FACE."
  (let ((eighths (round (* fraction 8 (length text))))
        (edge `( :foreground ,(face-background fill-face nil t)
                 :background ,(face-background face nil t))))
    (mapconcat
     (lambda (i)
       (let ((c (substring text i (1+ i)))
             (part (- eighths (* 8 i))))
         (cond ((>= part 8) (propertize c 'face fill-face))
               ((and (> part 0) (equal c " "))
                (propertize (substring widgetry-eighths part (1+ part)) 'face edge))
               (t (propertize c 'face (if (>= part 4) fill-face face))))))
     (number-sequence 0 (1- (length text))))))

;;;; Drawing

;; A widget is drawn by an overlay over text inserted once: redrawing
;; swaps the overlay's `display' and never touches the buffer text, its
;; properties or prefixes.  A widget's look is a list of parts, each
;; (TEXT FACE [FILL FILL-FACE]): TEXT in FACE, its first FILL (0.0 to
;; 1.0) in FILL-FACE, and DECO, a plist of SVG-only extras (see
;; `widgetry--svg-draw'); a terminal ignores DECO.  In a graphic frame the parts become one SVG image
;; of fixed size, filled to the pixel; in a terminal they become a string
;; of the same width, the fill edge an eighth-block glyph.

(defcustom widgetry-corner-radius 4
  "Pixels of the rounded corners of a widget in a graphic frame."
  :type 'natnum
  :group 'widgetry)

(defcustom widgetry-segment-gap 1
  "Pixels of background between touching segments of a group or chips."
  :type 'natnum
  :group 'widgetry)

(defun widgetry-part-divided (part)
  "PART with a `:divider' of `widgetry-segment-gap' pixels before it."
  (let ((part (append part (make-list (max 0 (- 4 (length part))) nil))))
    (append (seq-take part 4)
            (list (append (list :divider widgetry-segment-gap) (nth 4 part))))))

(defun widgetry--blend (colour other amount)
  "COLOUR (#RRGGBB) AMOUNT of the way towards OTHER."
  (apply #'format "#%02X%02X%02X"
         (cl-mapcar (lambda (a b) (round (/ (+ a (* amount (- b a))) 257)))
                    (color-values colour) (color-values other))))

(defun widgetry--text (parts frame)
  "The buffer text of PARTS on FRAME: their text, with the cell of a `:divider'
in a frame that draws no images."
  (mapconcat (lambda (part)
               (concat (and (not (widgetry-graphic-p frame))
                            (plist-get (nth 4 part) :divider)
                            (if (plist-get (nth 4 part) :break) "\n" " "))
                       (car part)))
             parts ""))

(defun widgetry-insert (widget)
  "Insert the text of WIDGET's parts, an overlay over it, and draw it.
For the `:value-create' of a widget whose `:parts' gives its look; a
space follows, outside the overlay."
  (let ((start (point)))
    (insert (widgetry--text (funcall (widget-get widget :parts) widget)
                            (widgetry--frame (current-buffer))))
    (let ((overlay (make-overlay start (point) nil t nil)))
      (overlay-put overlay 'evaporate t)
      (overlay-put overlay 'button widget)
      (overlay-put overlay 'widgetry widget)
      (unless (widget-get widget :read-only)
        (overlay-put overlay 'keymap (widget-get widget :keymap))
        (overlay-put overlay 'pointer 'hand)
        (when (widget-get widget :hoverable)
          (overlay-put overlay 'help-echo (widgetry-hover-help-echo widget))))
      (widget-put widget :widgetry-overlay overlay))
    (insert ?\s)
    (widgetry-redraw widget)))

;;;; Hover

(defcustom widgetry-hover-time 0.12
  "Seconds a widget takes to light up as the pointer enters it.
It fades out a quarter slower."
  :type 'number
  :group 'widgetry)

(defconst widgetry--hover-amount 0.18
  "Share of the way a fully hovered background goes towards its text colour.")

(defconst widgetry--hover-frame 0.03
  "Seconds between the steps of a running hover.")

(defvar widgetry--hovering nil
  "Widgets whose hover is lit or fading.")

(defvar widgetry--hover-timer nil
  "The timer stepping `widgetry--hovering', while there is any.")

(defun widgetry-hover-phase (widget &optional key)
  "How lit, 0.0 to 1.0, KEY (default t) of WIDGET is under the pointer."
  (or (alist-get key (widget-get widget :hover-alist)) 0.0))

(defun widgetry--hover-face (face phase frame)
  "FACE with its background PHASE of the way lit on FRAME."
  (let* ((bg (widgetry--color (widgetry--face-attribute face :background frame) frame "#2F2F2F"))
         (fg (widgetry--color (widgetry--face-attribute face :foreground frame) frame "#CBCBCB")))
    (widgetry--named-face
     face (apply #'color-rgb-to-hex
                 (append (color-blend (color-name-to-rgb fg frame) (color-name-to-rgb bg frame)
                                      (* widgetry--hover-amount phase))
                         '(2))))))

(defun widgetry--named-face (face background)
  "A named face like FACE on BACKGROUND, made once: drawing reads face symbols."
  (let ((name (intern (format "widgetry-hover--%s--%s" (if (symbolp face) face (sxhash-equal face))
                              background))))
    (unless (facep name)
      (make-face name)
      (set-face-attribute name nil :inherit face :background background))
    name))

(defun widgetry-hover-parts (parts phase)
  "PARTS with each background lit PHASE of the way; a terminal shows none."
  (let ((frame (widgetry--frame (current-buffer))))
    (if (or (<= phase 0.0) (not (display-graphic-p frame)))
        parts
      (mapcar (lambda (part)
                (cons (car part) (cons (widgetry--hover-face (cadr part) phase frame) (cddr part))))
              parts))))

(defun widgetry-pointer-offset (widget)
  "The column of the mouse pointer in WIDGET's image, or nil if it is not over it."
  (when-let* ((overlay (widget-get widget :widgetry-overlay))
              (buffer (overlay-buffer overlay))
              (window (get-buffer-window buffer))
              (pointer (mouse-pixel-position))
              ((eq (car pointer) (window-frame window)))
              ((cadr pointer))
              (posn (ignore-errors (posn-at-x-y (cadr pointer) (cddr pointer) (car pointer))))
              ((eq (posn-window posn) window))
              ((eql (posn-point posn) (overlay-start overlay)))
              (start (posn-at-point (overlay-start overlay) window)))
    (floor (- (cadr pointer) (car (window-inside-pixel-edges window)) (car (posn-x-y start)))
           (frame-char-width (car pointer)))))

(defun widgetry--hover-key (widget)
  "What of WIDGET the pointer is over: a key of its `:hover-alist', or nil."
  (if-let* ((function (widget-get widget :hover-key)))
      (funcall function widget)
    (and (widgetry-pointer-offset widget) t)))

(defun widgetry--hover-step (widget dt)
  "Move the lit parts of WIDGET DT seconds on; non-nil if any is still lit."
  (let* ((now (ignore-errors (widgetry--hover-key widget)))
         (alist (widget-get widget :hover-alist))
         (in (/ dt (max 0.001 widgetry-hover-time)))
         (out (/ dt (max 0.001 (* 1.25 widgetry-hover-time))))
         (new nil))
    (when (and now (not (assoc now alist)))
      (push (cons now 0.0) alist))
    (dolist (entry alist)
      (let ((phase (if (equal (car entry) now)
                       (min 1.0 (+ (cdr entry) in))
                     (max 0.0 (- (cdr entry) out)))))
        (when (or (> phase 0.0) (equal (car entry) now))
          (push (cons (car entry) phase) new))))
    (unless (equal new alist)
      (widget-put widget :hover-alist new)
      (widgetry-redraw widget))
    (or now (and new t))))

(defun widgetry--hover-tick ()
  "Step every hovering widget, and stop the timer when none is left."
  (setq widgetry--hovering
        (seq-filter (lambda (widget)
                      (let ((overlay (widget-get widget :widgetry-overlay)))
                        (and overlay (overlay-buffer overlay)
                             (widgetry--hover-step widget widgetry--hover-frame))))
                    widgetry--hovering))
  (unless widgetry--hovering
    (cancel-timer widgetry--hover-timer)
    (setq widgetry--hover-timer nil)))

(defun widgetry-hover-enter (widget)
  "Light WIDGET while the pointer is over it; called as the pointer moves in.
A terminal shows no hover.  Costs a timer only while something is lit."
  (when (and (display-graphic-p (widgetry--frame (current-buffer)))
             (not (widget-get widget :read-only))
             (not (memq widget widgetry--hovering)))
    (push widget widgetry--hovering)
    (unless widgetry--hover-timer
      (setq widgetry--hover-timer
            (run-with-timer 0 widgetry--hover-frame #'widgetry--hover-tick)))))

(defun widgetry-hover-help-echo (widget &optional text)
  "A `help-echo' function for WIDGET that lights it and gives TEXT."
  (lambda (&rest _) (widgetry-hover-enter widget) text))

(defun widgetry-value-set (widget value)
  "Set WIDGET to VALUE and redraw it; the `:value-set' of widgetry widgets."
  (widget-put widget :value value)
  (widgetry-redraw widget))

(defun widgetry-click-offset (widget event)
  "Offset into WIDGET's text of the mouse EVENT.
The overlay shows a display string or image, so the buffer position of a
click is always its start; the place within the display tells more."
  (let* ((posn (event-start event))
         (object (posn-object posn))
         (xy (posn-object-x-y posn))
         (width (posn-object-width-height posn))
         (length (length (widgetry-shown widget))))
    (cond ((and (consp object) (stringp (car object)) (integerp (cdr object)))
           (cdr object))
          ((and xy width (> (car width) 0))
           (min (1- length) (floor (* length (car xy)) (car width))))
          (t (- (posn-point posn)
                (overlay-start (widget-get widget :widgetry-overlay)))))))

;;;; Activation outline

(defcustom widgetry-flash-time 0.35
  "Seconds a widget keeps its outline after it activates."
  :type 'number
  :group 'widgetry)

(defun widgetry--accent (parts frame)
  "The accent colour of PARTS on FRAME: a fill's, else the first part's, else grey."
  (let ((part (or (seq-find (lambda (p) (and (nth 2 p) (nth 3 p))) parts) (car parts))))
    (widgetry--color (and part
                          (widgetry--face-attribute (or (nth 3 part) (nth 1 part))
                                                    :background frame))
                     frame "#9A9A9A")))

(defun widgetry--outline (parts frame)
  "PARTS with a solid outline in their accent colour, inside their bounds."
  (if (widgetry--deco parts :border)
      parts
    (widgetry--add-deco parts :border 'solid :border-color (widgetry--accent parts frame))))

(defcustom widgetry-flash-style '(border flash tick sweep)
  "How a widget shows that it activated, for `widgetry-flash-time'.
`border': an outline in its accent colour.  `flash': the whole widget
brightens, then fades back.  `tick': the tag shows a check mark.
`sweep': a highlight band crosses the widget once, left to right.
A list of them draws all together.  A widget's own `:flash-style'
overrides this.  A terminal frame shows only `tick', the rest nothing.
None of them moves the layout."
  :type '(set (const border) (const flash) (const tick) (const sweep))
  :group 'widgetry)

(defconst widgetry--flash-frame 0.04
  "Seconds between frames of an animated flash.")

(defun widgetry--flash-style (widget)
  "The flash style of WIDGET."
  (or (widget-get widget :flash-style) widgetry-flash-style))

(defun widgetry--flash-styles (widget)
  "The flash styles of WIDGET as a list."
  (let ((style (widgetry--flash-style widget)))
    (if (listp style) style (list style))))

(defun widgetry--add-deco (parts &rest deco)
  "PARTS with DECO added to the first part's decoration."
  (let ((first (car parts)))
    (cons (append (seq-take first 4) (make-list (max 0 (- 4 (length first))) nil)
                  (list (append deco (nth 4 first))))
          (cdr parts))))

(defun widgetry--tick (parts)
  "PARTS with the first part's text a check mark, of the same width."
  (let* ((text (car (car parts)))
         (lead (- (length text) (length (string-trim-left text))))
         (pad (max 0 (- (string-width text) lead 1))))
    (cons (cons (concat (make-string lead ?\s) "✓" (make-string pad ?\s))
                (cdr (car parts)))
          (cdr parts))))

(defun widgetry--flashed (widget parts frame)
  "PARTS of WIDGET as its running flash draws them on FRAME."
  (let* ((styles (widgetry--flash-styles widget))
         (frames (max 1 (round widgetry-flash-time widgetry--flash-frame)))
         (n (min frames (floor (- (float-time) (widget-get widget :flash-start))
                               widgetry--flash-frame)))
         (p (/ (float n) frames))
         (graphic (display-graphic-p frame)))
    (when (memq 'tick styles)
      (setq parts (widgetry--tick parts)))
    (when graphic
      (when (memq 'border styles) (setq parts (widgetry--outline parts frame)))
      (when (memq 'flash styles)
        (setq parts (widgetry--add-deco parts :wash (* 0.4 (- 1.0 p)))))
      (when (memq 'sweep styles) (setq parts (widgetry--add-deco parts :sweep p))))
    parts))

(defun widgetry-flash (widget)
  "Show WIDGET's flash for `widgetry-flash-time' seconds from now, and draw it.
Calling it again restarts the time; one timer serves the widget, ticking
per frame for the animated styles."
  (when-let* ((timer (widget-get widget :flash)))
    (cancel-timer timer))
  (let* ((start (float-time))
         (animated (or (memq 'flash (widgetry--flash-styles widget))
                       (memq 'sweep (widgetry--flash-styles widget))))
         (timer (run-with-timer
                 (if animated widgetry--flash-frame widgetry-flash-time)
                 (and animated widgetry--flash-frame)
                 (lambda ()
                   (when (>= (- (float-time) start) (- widgetry-flash-time 0.001))
                     (cancel-timer (widget-get widget :flash))
                     (widget-put widget :flash nil))
                   (widgetry-redraw widget)))))
    (widget-put widget :flash-start start)
    (widget-put widget :flash timer))
  (widgetry-redraw widget))

(defun widgetry--resync-text (overlay parts frame)
  "Make the buffer text under OVERLAY that of PARTS, when a changed tag or
label made it another length, so offsets into the widget stay right."
  (let ((text (widgetry--text parts frame))
        (start (overlay-start overlay))
        (end (overlay-end overlay)))
    (unless (= (length text) (- end start))
      (let ((inhibit-read-only t)
            (modified (buffer-modified-p)))
        (save-excursion
          (overlay-put overlay 'evaporate nil)
          (goto-char end)
          (insert text)
          (delete-region start end)
          (move-overlay overlay start (+ start (length text)))
          (overlay-put overlay 'evaporate t))
        (set-buffer-modified-p modified)))))

(defun widgetry-window-pixels (widget)
  "Pixels of text the window showing WIDGET has, less a two cell margin; nil if
none shows it.  The one width every widget lays out from: it changes with
rotation, the keyboard and split screen, so nothing may keep it."
  (when-let* ((overlay (widget-get widget :widgetry-overlay))
              (buffer (overlay-buffer overlay))
              (window (get-buffer-window buffer t)))
    (- (window-body-width window t) (* 2 (frame-char-width (window-frame window))))))

(defun widgetry-fit-cells (widget cells &optional used)
  "CELLS, or fewer so that CELLS and USED more cells fit the window of WIDGET."
  (if-let* ((pixels (widgetry-window-pixels widget)))
      (max 1 (min cells (- (/ pixels (frame-char-width)) (or used 0))))
    cells))

(defun widgetry-reflow (buffer)
  "Draw again the widgets of BUFFER with `:reflow': their layout depends on the
width of their window.  Called from `window-size-change-functions'."
  (with-current-buffer buffer
    (dolist (overlay (overlays-in (point-min) (point-max)))
      (let ((widget (overlay-get overlay 'button)))
        (when (and widget (widget-get widget :reflow))
          (widgetry-redraw widget))))))

(defun widgetry-redraw (widget)
  "Draw WIDGET again from its parts."
  (when-let* ((overlay (widget-get widget :widgetry-overlay))
              (buffer (overlay-buffer overlay))
              ((not (widget-get widget :editing))))
    (with-current-buffer buffer
      (when (widget-get widget :read-only)
        (overlay-put overlay 'keymap nil))
      (let* ((frame (widgetry--frame buffer))
             (parts (funcall (widget-get widget :parts) widget))
             (parts (if (widget-get widget :hover-own)
                        parts
                      (widgetry-hover-parts parts (widgetry-hover-phase widget)))))
        (widgetry--resync-text overlay parts frame)
        (overlay-put overlay 'display
                     (widgetry-display (if (widget-get widget :flash)
                                           (widgetry--flashed widget parts frame)
                                         parts)
                                       frame))))))

(defun widgetry-shown (widget)
  "What WIDGET shows as text: its look as in a terminal frame."
  (widgetry-cells (funcall (widget-get widget :parts) widget)))

(defun widgetry--frame (buffer)
  "The frame to draw for: one showing BUFFER, else a graphic one, else selected."
  (or (when-let* ((window (get-buffer-window buffer t))) (window-frame window))
      (seq-find #'display-graphic-p (frame-list))
      (selected-frame)))

(defvar widgetry-svg t
  "Non-nil to draw widgets as SVG images on a graphic frame.
Nil draws them as text everywhere: for an SVG renderer without fonts, such as
Android's.")

(defun widgetry-graphic-p (&optional frame)
  "Non-nil when FRAME (default the selected one) draws widgets as images.
The one capability check: everything else draws text cells."
  (and widgetry-svg (display-graphic-p frame) (image-type-available-p 'svg)))

(defun widgetry-display (parts &optional frame)
  "The display of PARTS on FRAME: an SVG image if it is graphic, else a string."
  (let ((frame (or frame (selected-frame))))
    (if (widgetry-graphic-p frame)
        (widgetry-svg parts frame)
      (widgetry-cells parts))))

(defvar widgetry-touch-scale nil
  "Nil, or the size multiplier of text widgets on a touch screen.
A text widget gets padding of this many text lines in all (half above, half
below) and at most 2 px at each side (every cell is padded, so more would push a
row off the screen).")

(defun widgetry-touch-face (face)
  "FACE with the padding of `widgetry-touch-scale' as an invisible box of its
background."
  (let ((bg (and (not (consp face)) (face-attribute face :background nil t))))
    (if (or (null widgetry-touch-scale) (not (stringp bg)))
        face
      (let ((v (round (* widgetry-touch-scale (frame-char-height) 0.5)))
            (h (min 2 (round (* widgetry-touch-scale (frame-char-width) 2)))))
        (list `(:box (:line-width (,h . ,v) :color ,bg)) face)))))

(defun widgetry-cells (parts)
  "PARTS as a string for a terminal frame, as wide as their text."
  (mapconcat (pcase-lambda (`(,text ,face ,fill ,fill-face . ,deco))
               (concat
                ;; A `:divider' (see `widgetry-part-divided') is one default-face cell.
                (and (plist-get (car deco) :divider)
                     (if (plist-get (car deco) :break) "\n" " "))
                (cond ((not (and fill fill-face)) (propertize text 'face (widgetry-touch-face face)))
                     ;; A negative FILL fills from the right, by whole cells.
                     ((< fill 0)
                      (let ((k (widgetry-fill-split (- fill) (length text)))
                            (face (widgetry-touch-face face)))
                        (concat (propertize (substring text 0 (- (length text) k)) 'face face)
                                (propertize (substring text (- (length text) k)) 'face fill-face))))
                     (t (widgetry-cell-filled-text text fill fill-face face)))))
             parts ""))

(defun widgetry--color (color frame fallback)
  "COLOR on FRAME as #RRGGBB, or FALLBACK."
  (if-let* ((values (and color (color-values color frame))))
      (apply #'format "#%02X%02X%02X" (mapcar (lambda (v) (/ v 257)) values))
    fallback))

(defun widgetry--face-attribute (face attribute frame)
  "ATTRIBUTE of FACE on FRAME; FACE may be a plist with `:inherit'."
  (if (consp face)
      (or (plist-get face attribute)
          (and (plist-get face :inherit)
               (widgetry--face-attribute (plist-get face :inherit) attribute frame)))
    (let ((value (face-attribute face attribute frame t)))
      (unless (eq value 'unspecified) value))))

(defun widgetry--paint (face frame)
  "Background, foreground and weight of FACE on FRAME, for SVG."
  (list (widgetry--color (widgetry--face-attribute face :background frame) frame "#2F2F2F")
        (widgetry--color (widgetry--face-attribute face :foreground frame) frame "#CBCBCB")
        (if (memq (widgetry--face-attribute face :weight frame) '(bold semi-bold extra-bold ultra-bold))
            "bold" "normal")))

(defun widgetry--metrics (frame)
  "Cell width, height, font family, font pixel size and ascent of FRAME."
  (let* ((width (frame-char-width frame))
         (height (frame-char-height frame))
         (info (ignore-errors (font-info (face-font 'default frame) frame))))
    (list width height
          (or (face-attribute 'default :family frame t) "monospace")
          (or (and info (aref info 2)) (round (* 0.8 height)))
          (or (and info (aref info 8)) (round (* 0.8 height))))))

(defvar widgetry--images (make-hash-table :test #'equal)
  "Images drawn so far, by their parts' paint and the frame's metrics.")

(defun widgetry--quantize (value)
  "VALUE with every float in it rounded to 1/200, so animation frames repeat.
A hover is time-driven: frames differing by less than a pixel would
otherwise each miss `widgetry--images' and be drawn and loaded again."
  (cond ((floatp value) (/ (fround (* value 200)) 200))
        ((consp value) (cons (widgetry--quantize (car value))
                             (widgetry--quantize (cdr value))))
        (t value)))

(defun widgetry--cells (text frame)
  "Cells TEXT needs in FRAME: its string width, or more when a glyph drawn
from a fallback font is wider than its cells (say a symbol like ⚙).  Only
the trimmed text is measured, so padding around a glyph absorbs its width."
  (let ((cells (string-width text)))
    (if (and frame (display-graphic-p frame) (fboundp 'string-pixel-width))
        (max cells (ceiling (with-selected-frame frame (string-pixel-width (string-trim text)))
                            (float (frame-char-width frame))))
      cells)))

(defun widgetry-svg (parts frame)
  "PARTS as an SVG image as wide as their text in FRAME's default font.
The image is the same size whatever the state: only colours change."
  (let* ((metrics (widgetry--metrics frame))
         (key (cons metrics
                    (mapcar (pcase-lambda (`(,text ,face ,fill ,fill-face ,deco))
                              (list text (widgetry--paint face frame) (widgetry--quantize (or fill 0.0))
                                    (and fill-face (widgetry--paint fill-face frame))
                                    (widgetry--quantize deco)))
                            parts))))
    (or (gethash key widgetry--images)
        (progn
          (when (> (hash-table-count widgetry--images) 512)
            (clrhash widgetry--images))
          (puthash key (widgetry--svg-draw (car key) (cdr key) frame) widgetry--images)))))

(defun widgetry--deco (parts key)
  "The first value of KEY in the DECO of PARTS."
  (seq-some (lambda (p) (plist-get (nth 4 p) key)) parts))

(defun widgetry--svg-box (svg cx cy size on deco)
  "A checkbox of SIZE pixels centred on CX CY in SVG: ON t ticks it, `partial'
dashes it."
  (let ((x (- cx (/ size 2.0))) (y (- cy (/ size 2.0))) (fill (plist-get deco :box-fill)))
    (svg-rectangle svg (+ x 0.75) (+ y 0.75) (- size 1.5) (- size 1.5) :rx widgetry-corner-radius
                   :fill (if on fill "none") :stroke (if on fill (plist-get deco :box-border))
                   :stroke-width 1.5)
    (when (eq on 'partial)
      (svg-line svg (+ x (* 0.28 size)) cy (+ x (* 0.72 size)) cy
                :stroke (widgetry-theme-colour 'default :background) :stroke-width (max 1.5 (* 0.12 size)) :stroke-linecap "round"))
    (when (eq on t)
      (svg-polyline svg (list (cons (+ x (* 0.25 size)) (+ y (* 0.52 size)))
                              (cons (+ x (* 0.43 size)) (+ y (* 0.70 size)))
                              (cons (+ x (* 0.76 size)) (+ y (* 0.33 size))))
                    :fill "none" :stroke (widgetry-theme-colour 'default :background)
                    :stroke-width (max 1.5 (* 0.12 size)) :stroke-linecap "round" :stroke-linejoin "round"))))

(defun widgetry--svg-draw (metrics parts &optional frame)
  "Draw PARTS, each (TEXT PAINT FILL FILL-PAINT DECO), with the METRICS of FRAME.
DECO of any part may hold, for the whole image: `:wash' OPACITY (a white
veil), `:sweep' FRACTION (a highlight band, that far across), and
`:border' solid (an outline in `:border-color').  For its own part:
`:track' FRACTION (a thin track along its bottom edge, filled from the
left by it in `:track-color'), `:bars' FRACTION (three ascending bars,
filled from the left by it), `:fill-opacity' of the fill, and `:box' on or
off (a checkbox in place of its text: a rounded square stroked in `:box-border',
filled in `:box-fill' with a white tick when on, a white dash when partial)."
  (pcase-let* ((`(,cw ,ch ,family ,size ,ascent) metrics)
               (width (* cw (apply #'+ (mapcar (lambda (p) (widgetry--cells (car p) frame)) parts))))
               (svg (svg-create width ch))
               (clip (svg-clip-path svg :id "w"))
               (border (widgetry--deco parts :border))
               (x 0)
               (i 0)
               (dividers nil))
    (svg-rectangle clip 0 0 width ch :rx widgetry-corner-radius)
    (let ((group (svg-node svg 'g :clip-path "url(#w)")))
      (pcase-dolist (`(,text ,paint ,fill ,fill-paint ,deco) parts)
        (when-let* ((gap (plist-get deco :divider))
                    ((> gap 0)))
          (push (list x gap (car paint)) dividers))
        (let* ((w (* cw (widgetry--cells text frame)))
               (h ch)
               ;; A negative FILL fills from the right.
               (filled (if fill-paint (round (* (abs fill) w)) 0))
               (fx (if (< fill 0) (+ x (- w filled)) x))
               (lead (- (length text) (length (string-trim-left text))))
               (label (string-trim text))
               (draw-text
                (lambda (node colour weight)
                  (unless (string-empty-p label)
                    (svg-text node label :x (+ x (* cw lead)) :y ascent
                              :font-family family :font-size size
                              :font-weight weight :fill colour
                              :xml:space "preserve")))))
          (svg-rectangle group x 0 w h :fill (car paint))
          (if-let* ((box (plist-get deco :box)))
              (widgetry--svg-box group (+ x (/ w 2.0)) (/ h 2.0) (* 0.72 h)
                                 (pcase box ('on t) ('partial 'partial)) deco)
            (funcall draw-text group (nth 1 paint) (nth 2 paint)))
          (when-let* ((track (plist-get deco :track)))
            (let ((th (max 2 (round (* 0.12 h)))))
              (svg-rectangle group x (- h th) w th :fill (nth 1 paint) :fill-opacity 0.25)
              (when (> track 0)
                (svg-rectangle group x (- h th) (* track w) th
                               :fill (or (plist-get deco :track-color) (widgetry-theme-colour 'success))))))
          (when-let* ((bars (plist-get deco :bars)))
            (let* ((bw (* 0.16 w)) (gap (* 0.08 w)) (x0 (+ x (/ (- w (* 3 bw) (* 2 gap)) 2.0)))
                   (bh (* 0.6 h)))
              (dotimes (k 3)
                (let ((hk (* bh (/ (+ k 2) 4.0))))
                  (svg-rectangle group (+ x0 (* k (+ bw gap))) (+ (* 0.2 h) (- bh hk)) bw hk
                                 :fill (nth 1 paint)
                                 :fill-opacity (if (> bars (/ k 3.0)) 1.0 0.3))))))
          (when (> filled 0)
            (let ((id (format "f%d" i)))
              (svg-rectangle (svg-clip-path svg :id id) fx 0 filled h)
              (let ((part (apply #'svg-node group 'g :clip-path (format "url(#%s)" id)
                                 (when-let* ((o (plist-get deco :fill-opacity)))
                                   (list :opacity o)))))
                (svg-rectangle part fx 0 filled h :fill (car fill-paint))
                (funcall draw-text part (nth 1 fill-paint) (nth 2 paint)))))
          (setq x (+ x w) i (1+ i))))
      ;; A strip of the background, a share of the way to the segment's own colour.
      (let ((bg (widgetry--color (widgetry--face-attribute 'default :background frame)
                                 frame "#2F2F2F")))
        (pcase-dolist (`(,dx ,gap ,colour) dividers)
          (svg-rectangle group dx 0 gap ch :fill (widgetry--blend colour bg 0.4))))
      (when-let* ((wash (widgetry--deco parts :wash)))
        (svg-rectangle group 0 0 width ch :fill (widgetry-theme-colour 'default) :fill-opacity wash))
      (when-let* ((sweep (widgetry--deco parts :sweep)))
        (let ((bw (* 0.25 width)))
          (svg-rectangle group (- (* sweep (+ width bw)) bw) 0 bw ch
                         :fill (widgetry-theme-colour 'default) :fill-opacity 0.3)))
      (when border
        (svg-rectangle group 1 1 (- width 2) (- ch 2) :rx (max 0 (1- widgetry-corner-radius))
                       :fill "none" :stroke (or (widgetry--deco parts :border-color) (widgetry-theme-colour 'default))
                       :stroke-width 1.5 :stroke-linecap "round"
                       :stroke-dasharray "none")))
    (svg-image svg :ascent 'center)))

;;;; Dragging

(defvar widgetry-active-gesture nil
  "The widget being dragged or held, while a mouse gesture follows it.
Code that rebuilds a buffer of widgets should wait while this is non-nil,
or the gesture loses its widget.")

(defcustom widgetry-drag-threshold 30
  "Pixels to drag a widget for one step (selector) or to flip it (toggle)."
  :type 'natnum
  :group 'widgetry)

(defcustom widgetry-tty-cell-pixels 10
  "Pixels one character cell counts for when dragging in a terminal frame.
A terminal reports the mouse by the cell, so a drag there moves this
many pixels per cell: `widgetry-drag-threshold' and the slider step then
stay what they are in a graphic frame, a few cells per step."
  :type 'natnum
  :group 'widgetry)

(defun widgetry-cell-scale ()
  "Pixels one unit of a mouse position stands for in the selected frame.
1 in a graphic frame, `widgetry-tty-cell-pixels' in a terminal one."
  (if (display-graphic-p) 1 widgetry-tty-cell-pixels))

(defun widgetry-distance (from to)
  "Pixels dragged from FROM to TO (x . y): right and up are positive."
  (+ (- (car to) (car from))
     (- (cdr from) (cdr to))))

(defun widgetry-steps (distance &optional threshold)
  "Whole steps in DISTANCE pixels: one per THRESHOLD, towards zero.
THRESHOLD defaults to `widgetry-drag-threshold'."
  (truncate distance (or threshold widgetry-drag-threshold)))

(defvar xterm-mouse-mode)
(defvar touch-screen-events-received)

(defun widgetry--read-key-p ()
  "Non-nil when gestures must be read with `read-key': a terminal mouse or a touch
screen.
`read-event' hands touch events over raw (touchscreen-update, touchscreen-end);
only `read-key' applies the translation to the mouse events a gesture follows."
  (or (bound-and-true-p touch-screen-events-received)
      (and xterm-mouse-mode (not (display-graphic-p)))))

(defun widgetry-read-event (&optional timeout)
  "Read an event, waiting at most TIMEOUT seconds, or nil.
In a terminal frame the mouse comes as escape sequences that only a key
read decodes (`xterm-mouse-mode'); `read-event' would hand them over as
keys, so a tap's release would never end a gesture there."
  (if (not (widgetry--read-key-p))
      (read-event nil nil timeout)
    (if timeout
        (with-timeout (timeout nil) (read-key nil t))
      (read-key nil t))))

(defun widgetry--read-potential ()
  "The next event of a gesture: through `read-key' on a touch screen."
  (if (bound-and-true-p touch-screen-events-received)
      (read-key nil t)
    (read--potential-mouse-event)))

(defun widgetry--read-latest-event ()
  "Read an event, skipping mouse movements that a newer one has overtaken.
A drag redraws its widget per movement; when the mouse moves faster than
that, only the newest position matters.  In a terminal frame the mouse
comes as escape sequences that only a key read decodes (`xterm-mouse-mode'),
so this reads as `read--potential-mouse-event' does."
  (let ((event (widgetry--read-potential))
        (done nil))
    (while (and (not done)
                (eq (car-safe event) 'mouse-movement)
                (input-pending-p))
      (let ((next (widgetry--read-potential)))
        (if (eq (car-safe next) 'mouse-movement)
            (setq event next)
          ;; Not a movement: give it back for the next read
          (push next unread-command-events)
          (setq done t))))
    event))

(defun widgetry-drag (function &optional horizontal)
  "Follow the mouse until it is released, calling FUNCTION with the distance.
The distance is in pixels from where the mouse first moved (see
`widgetry-distance'), or only its horizontal part when HORIZONTAL is
non-nil; in a terminal frame each cell counts as `widgetry-cell-scale'
pixels.  Return non-nil if the mouse moved at all, nil for a plain click."
  (let ((start nil)
        (moved nil)
        (scale (widgetry-cell-scale))
        ;; A movement per pixel, not per character cell
        (mouse-fine-grained-tracking t)
        (widgetry-active-gesture t))
    (setq cursor-type nil)
    (unwind-protect
        (track-mouse
          (while-let ((event (widgetry--read-latest-event))
                      ((eq (car-safe event) 'mouse-movement)))
            (when-let* ((position (event-start event))
                        (window (posn-window position))
                        ((window-live-p window))
                        (x-y (posn-x-y position))
                        (edges (window-inside-pixel-edges window)))
              (let ((at (cons (+ (car x-y) (car edges)) (+ (cdr x-y) (cadr edges)))))
                (unless start (setq start at))
                (let ((distance (* scale (if horizontal
                                             (- (car at) (car start))
                                           (widgetry-distance start at)))))
                  (unless (zerop distance)
                    (setq moved t)
                    (funcall function distance)))))))
      (setq cursor-type t))
    moved))

;;;; Mode

(defvar widgetry-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map widget-keymap)
    (define-key map [down-mouse-1] #'mouse-set-point)
    (dolist (key '([drag-mouse-1] [double-mouse-1] [triple-mouse-1]
                   [double-down-mouse-1] [triple-down-mouse-1]))
      (define-key map key #'ignore))
    map)
  "Keymap of `widgetry-mode'.")

(defvar evil-emacs-state-modes)
(declare-function evil-emacs-state "evil-states")

;;;###autoload
(define-minor-mode widgetry-mode
  "Minor mode for buffers of widgetry widgets.
The mouse sets point and does not select text.  With evil, the buffer
uses Emacs state, so the keys of the widgets reach them."
  :lighter nil
  :keymap widgetry-mode-map
  (when (and widgetry-mode (fboundp 'evil-emacs-state))
    (evil-emacs-state)))

(provide 'widgetry-core)
;;; widgetry-core.el ends here
