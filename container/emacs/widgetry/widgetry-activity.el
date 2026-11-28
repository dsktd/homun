;;; widgetry-activity.el --- What something did last, as coloured cells -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; An activity is a list of events, oldest first.  An event is a plist
;; whose :kind is one of `widgetry-activity-kinds': think, text, read,
;; edit, bash, agent, wait, err or idle.  Each kind has a glyph, a face
;; (`widgetry-activity-KIND', so a theme can change the colours) and a
;; word for what is being done.  An event may also carry :tool and
;; :summary (what it worked on), :time (epoch seconds) and :pending (a
;; wait that has not been answered).
;;
;; `widgetry-activity-strip' draws the newest events as one cell each,
;; newest on the right:
;;
;;   (insert (widgetry-activity-strip events 14))
;;
;; Each cell says on hover what it was and when; the newest one also
;; what is being done now.  `widgetry-activity-pulse' lights the newest
;; cell of a region for `widgetry-flash-time', and
;; `widgetry-activity-blink' makes the unanswered waits of a buffer
;; blink until none is left.  `widgetry-activity-latest' names the
;; newest event next to a dot in its colour: "● edit".
;;
;; `widgetry-activity-blocks' draws the same events by how long each
;; lasted: a run of █ in the colour of its kind, as long as the time to
;; the next event, on a scale of seconds a cell.
;;
;;   (insert (widgetry-activity-blocks events 24 5))

;;; Code:

(require 'cl-lib)
(require 'widgetry-core)

(defface widgetry-activity-think '((t (:inherit font-lock-comment-face)))
  "Face for a thought in an activity."
  :group 'widgetry)

(defface widgetry-activity-text '((t (:inherit font-lock-string-face)))
  "Face for written text in an activity."
  :group 'widgetry)

(defface widgetry-activity-read '((t (:inherit font-lock-function-name-face)))
  "Face for reading or searching in an activity."
  :group 'widgetry)

(defface widgetry-activity-edit '((t (:inherit font-lock-constant-face)))
  "Face for an edit in an activity."
  :group 'widgetry)

(defface widgetry-activity-bash '((t (:inherit font-lock-type-face)))
  "Face for a command run in an activity."
  :group 'widgetry)

(defface widgetry-activity-agent '((t (:inherit font-lock-keyword-face)))
  "Face for work handed to an agent in an activity."
  :group 'widgetry)

(defface widgetry-activity-wait '((t (:inherit (bold error))))
  "Face for waiting on the user in an activity."
  :group 'widgetry)

(defface widgetry-activity-err '((t (:inherit error)))
  "Face for an error in an activity."
  :group 'widgetry)

(defface widgetry-activity-idle '((t (:inherit shadow)))
  "Face for nothing happening in an activity."
  :group 'widgetry)

(defface widgetry-activity-pulse '((t (:inherit highlight :weight bold)))
  "Face laid over the newest cell of an activity while it pulses."
  :group 'widgetry)

(defcustom widgetry-activity-blink-time 0.5
  "Seconds an unanswered wait is shown, then hidden, while it blinks."
  :type 'number
  :group 'widgetry)

(defconst widgetry-activity-kinds
  '((think "▪" widgetry-activity-think "thinking")
    (text  "▪" widgetry-activity-text  "writing")
    (read  "▪" widgetry-activity-read  "reading")
    (edit  "▪" widgetry-activity-edit  "editing")
    (bash  "▪" widgetry-activity-bash  "running")
    (agent "◆" widgetry-activity-agent "delegating")
    (wait  "!" widgetry-activity-wait  "waiting for an answer")
    (err   "✗" widgetry-activity-err   "failed")
    (idle  "·" widgetry-activity-idle  "idle"))
  "The kinds of an activity event: (KIND GLYPH FACE DOING).")

(defun widgetry-activity--kind (kind)
  "The entry of KIND in `widgetry-activity-kinds'; that of idle for an unknown one."
  (or (assq kind widgetry-activity-kinds) (assq 'idle widgetry-activity-kinds)))

(defun widgetry-activity-glyph (kind)
  "The one-cell glyph of KIND."
  (nth 1 (widgetry-activity--kind kind)))

(defun widgetry-activity-face (kind)
  "The face of KIND."
  (nth 2 (widgetry-activity--kind kind)))

(defun widgetry-activity-doing (kind)
  "What is being done during KIND, as a word: \"editing\"."
  (nth 3 (widgetry-activity--kind kind)))

;;; The strip: one cell an event

(defun widgetry-activity-describe (event &optional newest)
  "What EVENT was, for a tooltip: \"edit · Edit run.nu · 14:32:05\".
With NEWEST a second line says what is being done now."
  (let* ((kind (or (plist-get event :kind) 'idle))
         (what (string-join (delq nil (list (plist-get event :tool) (plist-get event :summary))) " "))
         (time (plist-get event :time)))
    (concat (string-join (delq nil (list (symbol-name kind)
                                         (and (not (string-empty-p what)) what)
                                         (and time (format-time-string "%H:%M:%S" time))))
                         " · ")
            (and newest (format "\ncurrently: %s" (widgetry-activity-doing kind))))))

(defun widgetry-activity-cell (event &optional newest)
  "The cell of EVENT: the glyph of its kind in its face, described on hover.
The NEWEST cell and an unanswered wait are marked with the text properties
`widgetry-activity-newest' and `widgetry-activity-wait'."
  (let ((kind (or (plist-get event :kind) 'idle)))
    (apply #'propertize (widgetry-activity-glyph kind)
           'face (widgetry-activity-face kind)
           'help-echo (widgetry-activity-describe event newest)
           (append (and newest '(widgetry-activity-newest t))
                   (and (eq kind 'wait) (plist-get event :pending)
                        '(widgetry-activity-wait t))))))

(defun widgetry-activity-strip (events width)
  "The newest WIDTH of EVENTS (oldest first) as cells, newest on the right.
Fewer events leave idle cells on the left."
  (let* ((shown (last events width))
         (newest (car (last shown))))
    (concat (mapconcat (lambda (_) (widgetry-activity-cell '(:kind idle)))
                       (make-list (- width (length shown)) nil) "")
            (mapconcat (lambda (event) (widgetry-activity-cell event (eq event newest)))
                       shown ""))))

(defconst widgetry-activity-latest-width
  (+ 2 (apply #'max (mapcar (lambda (kind) (length (symbol-name (car kind))))
                            widgetry-activity-kinds)))
  "Cells `widgetry-activity-latest' fills.")

(defun widgetry-activity-latest (events)
  "The newest of EVENTS (oldest first) as a dot and its kind: \"● edit\".
Idle without events; always `widgetry-activity-latest-width' cells.  The dot
of an unanswered wait is marked like its cell, so it blinks with it."
  (let* ((event (or (car (last events)) '(:kind idle)))
         (kind (plist-get event :kind))
         (face (widgetry-activity-face kind)))
    (concat (apply #'propertize "●" 'face face 'help-echo (widgetry-activity-describe event t)
                   (and (eq kind 'wait) (plist-get event :pending) '(widgetry-activity-wait t)))
            " "
            (propertize (string-pad (symbol-name kind) (- widgetry-activity-latest-width 2))
                        'face face))))

;;; Blocks: a run of cells as long as an event lasted

(defun widgetry-activity-blocks (events width seconds &optional now idle-after)
  "EVENTS (oldest first) as WIDTH cells of SECONDS each, ending at NOW.
A cell is a █ in the face of the event that was the latest at its time, so an
event shows as a run as long as it lasted: until the next event, the last one
until NOW (default: the current time).  A cell before the first event is an
idle one, and so is a cell more than IDLE-AFTER seconds after its event when
that is given.  Events without a :time are left out."
  (let* ((now (or now (float-time)))
         (timed (seq-filter (lambda (event) (plist-get event :time)) events)))
    (mapconcat
     (lambda (index)
       ;; The middle of the cell decides what it shows
       (let* ((at (- now (* seconds (- width index 0.5))))
              (event (car (last (seq-take-while (lambda (event) (<= (plist-get event :time) at))
                                                timed)))))
         (if (and event (not (eq (plist-get event :kind) 'idle))
                  (not (and idle-after (> (- at (plist-get event :time)) idle-after))))
             (propertize "█" 'face (widgetry-activity-face (plist-get event :kind))
                         'help-echo (widgetry-activity-describe event))
           (widgetry-activity-cell '(:kind idle)))))
     (number-sequence 0 (1- width)) "")))

(defun widgetry-activity--marked (property start end)
  "The (FROM . TO) stretches of text with PROPERTY between START and END."
  (let ((pos start) found)
    (while (and pos (< pos end))
      (let ((next (or (next-single-property-change pos property nil end) end)))
        (when (get-text-property pos property) (push (cons pos next) found))
        (setq pos next)))
    (nreverse found)))

;; A pulse overlay is deleted by a `homun-clock' client once its time is up; no timer of its own.
(defvar widgetry-activity--pulses nil "List of (OVERLAY . DEADLINE) of the pulses showing.")

(defun widgetry-activity--pulse-frame (&optional _snap)
  "Delete the pulses past their deadline.  Return non-nil while any is left."
  (let ((now (float-time)))
    (setq widgetry-activity--pulses
          (seq-filter (lambda (pulse)
                        (or (< now (cdr pulse)) (progn (delete-overlay (car pulse)) nil)))
                      widgetry-activity--pulses))))

(defun widgetry-activity-pulse (start end)
  "Light the newest activity cell between START and END for `widgetry-flash-time'.
Nothing happens when `widgetry-flash-style' is nil."
  (when widgetry-flash-style
    (pcase-dolist (`(,from . ,to) (widgetry-activity--marked 'widgetry-activity-newest start end))
      (let ((overlay (make-overlay from to)))
        (overlay-put overlay 'face 'widgetry-activity-pulse)
        (overlay-put overlay 'evaporate t)
        (push (cons overlay (+ (float-time) widgetry-flash-time)) widgetry-activity--pulses)
        (homun-clock-register 'widgetry-pulse #'widgetry-activity--pulse-frame)))))

;; Blinking runs on `homun-clock' while its buffer is shown and holds an unanswered wait; it
;; only adds and removes overlays.
(defvar-local widgetry-activity--blink nil "Non-nil while the waits of this buffer blink.")
(defvar-local widgetry-activity--blink-at 0 "When the waits of this buffer last blinked.")

(defun widgetry-activity--blink-stop (buffer)
  "Stop blinking in BUFFER and show its waits."
  (homun-clock-unregister (cons 'widgetry-blink buffer))
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq widgetry-activity--blink nil)
      (remove-overlays (point-min) (point-max) 'widgetry-activity-blink t))))

(defun widgetry-activity--blink-tick (buffer)
  "Hide the unanswered waits of BUFFER, or show them again.
Return non-nil while the buffer goes on blinking."
  (condition-case nil
      (if (not (and (buffer-live-p buffer) (get-buffer-window buffer t)
                    (buffer-local-value 'widgetry-activity--blink buffer)))
          (progn (widgetry-activity--blink-stop buffer) nil)
        (with-current-buffer buffer
          (let ((waits (widgetry-activity--marked 'widgetry-activity-wait (point-min) (point-max)))
                (hidden (seq-some (lambda (overlay) (overlay-get overlay 'widgetry-activity-blink))
                                  (overlays-in (point-min) (point-max)))))
            (remove-overlays (point-min) (point-max) 'widgetry-activity-blink t)
            (cond ((null waits) (widgetry-activity--blink-stop buffer) nil)
                  (t (unless hidden
                       (pcase-dolist (`(,from . ,to) waits)
                         (let ((overlay (make-overlay from to)))
                           (overlay-put overlay 'widgetry-activity-blink t)
                           (overlay-put overlay 'evaporate t)
                           (overlay-put overlay 'display (make-string (- to from) ?\s)))))
                     t)))))
    (error (widgetry-activity--blink-stop buffer) nil)))

(defun widgetry-activity--blink-frame (buffer)
  "The clock client of BUFFER: blink once per `widgetry-activity-blink-time'."
  (let ((now (float-time)))
    (if (or (not (buffer-live-p buffer))
            (< (- now (buffer-local-value 'widgetry-activity--blink-at buffer))
               widgetry-activity-blink-time))
        (buffer-live-p buffer)
      (with-current-buffer buffer (setq widgetry-activity--blink-at now))
      (widgetry-activity--blink-tick buffer))))

(defun widgetry-activity-blink (&optional buffer)
  "Make the unanswered waits of BUFFER (default: the current one) blink.
They blink until none is left or the buffer is no longer shown; call this
again after drawing new ones."
  (let ((buffer (or buffer (current-buffer))))
    (with-current-buffer buffer
      (when (and (not widgetry-activity--blink)
                 (widgetry-activity--marked 'widgetry-activity-wait (point-min) (point-max)))
        (setq widgetry-activity--blink t widgetry-activity--blink-at (float-time))
        (homun-clock-register (cons 'widgetry-blink buffer)
                              (lambda (_snap) (widgetry-activity--blink-frame buffer)))))))

(provide 'widgetry-activity)
;;; widgetry-activity.el ends here
