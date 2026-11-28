;;; homun-stage-live.el --- Live rows and sparklines under a scene, on homun-clock -*- lexical-binding: t -*-

;; Under a scene of `homun-stage-live-scenes' (first "work-map") the Stage draws a strip of
;; sparklines.  The rows themselves belong to the scene's own list (the Items of
;; homun-stage-rows.el), which draws each through `homun-stage-live-draw-row': one row per task,
;; with the live decorations in its spans.
;; A row is one line of text whose three spans (spinner or mark, elapsed time, progress bar)
;; have a fixed width, so the clock replaces just that span: O(changed) per frame.  A new row
;; slides and fades in over `homun-stage-live-fade' seconds (face blending), a row that ended
;; flashes its check mark for `homun-stage-live-flash' seconds, then settles and leaves the
;; active list.  Every span is a pure function of the time, so a hidden stage needs no catching
;; up: the clock pauses with the window and the next frame draws the right state.
;; Sparklines (5h budget, agent slots in use, freeze stalls) are SVG bars on a graphic frame
;; with the glyphs ▁▂▃▅▇ as their text; their data refreshes every 30 s in an idle timer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'color)
(require 'svg)
(require 'homun-clock)
(require 'widgetry-core)

(defvar homun-stage-live-fade 0.2 "Seconds a new row takes to slide and fade in.")
(defvar homun-stage-live-flash 1.0 "Seconds a finished row flashes its check mark.")
(defvar homun-stage-live-spark-refresh 30 "Seconds between reads of the sparkline data.")
(defvar homun-stage-live-spark-points 16 "Glyphs (bars) of a sparkline.")
(defvar homun-stage-live-scenes nil "Ids of the scenes that get the sparkline strip.")
(defvar homun-stage-live-spark-sources nil
  "List of (KEY LABEL FUNCTION); FUNCTION returns (VALUES MAX SUFFIX) of a
sparkline, or nil.")

(defface homun-stage-live-spin '((t (:inherit font-lock-keyword-face))) "The spinner of a running row." :group 'homun-layout)
(defface homun-stage-live-flash '((t (:inherit success :weight bold :inverse-video t))) "A check mark just made." :group 'homun-layout)

(cl-defstruct (homun-stage-live-row (:constructor homun-stage-live-row--make) (:copier nil))
  id label state start end progress born
  beg-spin beg-time beg-bar fade-ov (fade -1) (shown (vector nil nil nil)))

(defvar-local homun-stage-live--rows nil "Hash of row id to its `homun-stage-live-row'.")
(defvar-local homun-stage-live--active nil "The rows that still animate.")
(defvar-local homun-stage-live--sparks nil "List of (KEY MARKER LENGTH LAST) of the sparklines drawn.")
(defvar homun-stage-live--buffers nil "Buffers that hold a strip.")
(defvar homun-stage-live--spark-at 0)
(defvar homun-stage-live--spark-cache nil "Alist of key to (VALUES MAX SUFFIX).")

;;; Pure pieces

(defun homun-stage-live-spinner (now)
  "The `widgetry-spinner-frames' frame at time NOW."
  (aref widgetry-spinner-frames
        (mod (floor now widgetry-spinner-interval) (length widgetry-spinner-frames))))

(defun homun-stage-live-elapsed (secs)
  "SECS as 1m23s, 4s or 2h05m, six columns wide."
  (let ((s (max 0 (floor secs))))
    (format "%6s" (cond ((< s 60) (format "%ds" s))
                        ((< s 3600) (format "%dm%02ds" (/ s 60) (% s 60)))
                        (t (format "%dh%02dm" (/ s 3600) (% (/ s 60) 60)))))))

(defun homun-stage-live-bar (frac)
  "A ten-cell bar and a percentage of FRAC (15 columns), or blanks when FRAC is
nil."
  (if (not (numberp frac)) (make-string 15 ?\s)
    (let* ((f (max 0.0 (min 1.0 frac))) (n (round (* 10 f))))
      (format "%s%s %3d%%" (make-string n ?█) (make-string (- 10 n) ?░) (round (* 100 f))))))

(defun homun-stage-live-glyphs (values max)
  "VALUES as glyphs of ▁▂▃▅▇ scaled to MAX (a space for nil)."
  (concat (mapcar (lambda (v) (if v (aref "▁▂▃▅▇" (round (* 4 (min 1.0 (/ (float v) (max max 1e-9)))))) ?\s))
                  values)))

(defun homun-stage-live--blend (a b x)
  "The colour X of the way from colour A to B as #rrggbb, or nil when a name is
unknown."
  (let ((ca (color-name-to-rgb a)) (cb (color-name-to-rgb b)))
    (when (and ca cb)
      (apply #'color-rgb-to-hex (append (cl-mapcar (lambda (p q) (+ p (* x (- q p)))) ca cb) '(2))))))

(defun homun-stage-live--mark (st now)
  "The one-column mark of the row ST at NOW: (STRING . FACE)."
  (pcase (homun-stage-live-row-state st)
    ("running" (cons (homun-stage-live-spinner now) 'homun-stage-live-spin))
    ("wait" (cons "…" 'warning))
    ("failed" (cons "✗" 'error))
    ("done" (cons "✓" (if (< (- now (or (homun-stage-live-row-end st) 0)) homun-stage-live-flash)
                          'homun-stage-live-flash 'success)))
    (_ (cons "○" 'shadow))))

(defun homun-stage-live--view (st now)
  "What the spans of ST show at NOW: [MARK TIME BAR], propertized strings of fixed
width."
  (let* ((mark (homun-stage-live--mark st now)) (start (homun-stage-live-row-start st))
         (end (or (homun-stage-live-row-end st) now)) (state (homun-stage-live-row-state st)))
    (vector (propertize (car mark) 'face (cdr mark))
            (if (and start (member state '("running" "done" "failed")))
                (homun-stage-live-elapsed (- end start)) (make-string 6 ?\s))
            (homun-stage-live-bar (if (equal state "done") (or (homun-stage-live-row-progress st) 1.0)
                                    (homun-stage-live-row-progress st))))))

;;; Spans

(defun homun-stage-live--put (marker len string)
  "Replace LEN characters at MARKER with STRING (the same width) without marking
the buffer modified."
  (with-silent-modifications
    (save-excursion
      (goto-char marker) (insert string) (delete-region (point) (+ (point) len)))))

(defun homun-stage-live--fade-step (st now)
  "The fade step 0..6 of ST at NOW (6 is settled)."
  (min 6 (floor (* 6 (/ (- now (homun-stage-live-row-born st)) homun-stage-live-fade)))))

(defun homun-stage-live--fade (st step)
  "Put the slide and fade of STEP on the overlay of ST; end it at 6."
  (let ((ov (homun-stage-live-row-fade-ov st)))
    (if (>= step 6)
        (when ov (delete-overlay ov) (setf (homun-stage-live-row-fade-ov st) nil))
      (when ov
        (let* ((x (/ step 6.0))
               (c (homun-stage-live--blend (face-background 'default nil t) (face-foreground 'default nil t) x)))
          (overlay-put ov 'face (if c `(:foreground ,c) (if (< x 0.5) 'shadow 'default)))
          (overlay-put ov 'before-string
                       (propertize " " 'display `(space :width ,(round (* 3 (- 1 x)))))))))
    (setf (homun-stage-live-row-fade st) step)))

(defun homun-stage-live--step (st now snap)
  "Bring the spans of ST up to NOW.  Non-nil while ST goes on animating.  SNAP ends
fades and flashes."
  (let ((view (homun-stage-live--view st now)) (shown (homun-stage-live-row-shown st))
        (begs (list (homun-stage-live-row-beg-spin st) (homun-stage-live-row-beg-time st)
                    (homun-stage-live-row-beg-bar st)))
        (lens (quote (1 6 15))) (step (if snap 6 (homun-stage-live--fade-step st now))))
    (dotimes (i 3)
      (unless (equal-including-properties (aref view i) (aref shown i))
        (homun-stage-live--put (nth i begs) (nth i lens) (aref view i))
        (aset shown i (aref view i))))
    (unless (= step (homun-stage-live-row-fade st)) (homun-stage-live--fade st step))
    (or (equal (homun-stage-live-row-state st) "running") (< step 6)
        (and (equal (homun-stage-live-row-state st) "done") (not snap)
             (< (- now (or (homun-stage-live-row-end st) 0)) (+ homun-stage-live-flash 0.1))))))

;;; Rows and sparklines in the buffer

(defun homun-stage-live--sync-row (spec now)
  "The row of SPEC (ID LABEL STATE START PROGRESS): made if new, ended-at stamped
on a change to done."
  (pcase-let* ((`(,id ,label ,state ,start ,progress) spec)
               (st (or (gethash id homun-stage-live--rows)
                       (puthash id (homun-stage-live-row--make :id id :born now :state state) homun-stage-live--rows))))
    (when (and (equal state "done") (not (equal (homun-stage-live-row-state st) "done")))
      (setf (homun-stage-live-row-end st) now))
    (when (and (equal state "done") (null (homun-stage-live-row-end st)))
      (setf (homun-stage-live-row-end st) (- now homun-stage-live-flash 1)))
    (setf (homun-stage-live-row-state st) state (homun-stage-live-row-label st) label
          (homun-stage-live-row-progress st) progress
          (homun-stage-live-row-start st) (or start (homun-stage-live-row-start st)
                                              (and (equal state "running") now)))
    st))

(defun homun-stage-live--release (st)
  "Free the overlay and markers of the last drawing of ST: a render erased their
text."
  (when-let* ((ov (homun-stage-live-row-fade-ov st))) (delete-overlay ov))
  (dolist (m (list (homun-stage-live-row-beg-spin st) (homun-stage-live-row-beg-time st)
                   (homun-stage-live-row-beg-bar st)))
    (when (markerp m) (set-marker m nil))))

(defun homun-stage-live--ensure ()
  "Make the row table of this buffer and register it with the clock."
  (unless homun-stage-live--rows (setq homun-stage-live--rows (make-hash-table :test #'equal)))
  (cl-pushnew (current-buffer) homun-stage-live--buffers)
  (unless (assq 'stage-live homun-clock--clients) (homun-clock-register 'stage-live #'homun-stage-live--tick))
  (homun-clock-dirty 'stage-live))

(defun homun-stage-live-draw-row (spec)
  "Insert the line of SPEC (ID LABEL STATE START PROGRESS) at point, without its
newline.
The line is the mark (spinner), the label, the elapsed time and the progress
bar, the decorations in spans the clock redraws in place.  Returns the start of
the line."
  (homun-stage-live--ensure)
  (let* ((now (funcall homun-clock-time-function)) (st (homun-stage-live--sync-row spec now))
         (view (homun-stage-live--view st now)) (line (point)))
    (homun-stage-live--release st)
    (insert " ")
    (setf (homun-stage-live-row-beg-spin st) (copy-marker (point)))
    (insert (aref view 0) " " (or (homun-stage-live-row-label st) "") " ")
    (setf (homun-stage-live-row-beg-time st) (copy-marker (point)))
    (insert (aref view 1) " ")
    (setf (homun-stage-live-row-beg-bar st) (copy-marker (point)))
    (insert (aref view 2))
    (setf (homun-stage-live-row-shown st) view (homun-stage-live-row-fade st) -1
          (homun-stage-live-row-fade-ov st) (make-overlay line (point)))
    (cl-pushnew st homun-stage-live--active)
    line))

(defun homun-stage-live-prune (ids)
  "Forget the rows whose id is not in IDS, after a render drew the rest."
  (maphash (lambda (id st)
             (unless (member id ids)
               (when-let* ((ov (homun-stage-live-row-fade-ov st))) (delete-overlay ov))
               (remhash id homun-stage-live--rows)))
           homun-stage-live--rows)
  (setq homun-stage-live--active
        (cl-delete-if-not (lambda (st) (eq st (gethash (homun-stage-live-row-id st) homun-stage-live--rows)))
                          homun-stage-live--active)))

(defun homun-stage-live--spark-image (values max)
  "An SVG of bars for VALUES, or nil on a text frame."
  (when (and (widgetry-graphic-p) (require 'homun-stage nil t))
    (let* ((cw (frame-char-width)) (h (frame-char-height)) (svg (svg-create (* cw (length values)) h))
           (fill (alist-get 'accent (homun-stage-palette))))
      (cl-loop for v in values for i from 0 when v
               do (let ((bh (max 1 (round (* h (min 1.0 (/ (float v) (max max 1e-9))))))))
                    (svg-rectangle svg (* i cw) (- h bh) (max 1 (- cw 1)) bh :fill fill)))
      (svg-image svg :ascent 'center))))

(defun homun-stage-live--spark-string (data)
  "The fixed-width span for DATA (VALUES MAX SUFFIX): bars (an image on graphics),
a space, the suffix."
  (pcase-let* ((`(,values ,max ,suffix) data) (n homun-stage-live-spark-points)
               (values (append (make-list (max 0 (- n (length values))) nil) (last values n)))
               (glyphs (homun-stage-live-glyphs values max))
               (image (homun-stage-live--spark-image values max)))
    (concat (if image (propertize glyphs 'display image 'rear-nonsticky t) glyphs)
            (format " %-5s" (or suffix "")))))

(defun homun-stage-live--insert-spark (key label)
  (let* ((data (alist-get key homun-stage-live--spark-cache)) (str (homun-stage-live--spark-string (or data '(nil 1 nil)))))
    (insert "  " (format "%-10s" label))
    (push (list key (copy-marker (point)) (length str) str) homun-stage-live--sparks)
    (insert str "\n")))

(defun homun-stage-live--insert-sparks ()
  (dolist (sp homun-stage-live--sparks) (set-marker (nth 1 sp) nil))
  (setq homun-stage-live--sparks nil)
  (pcase-dolist (`(,key ,label ,_) homun-stage-live-spark-sources)
    (homun-stage-live--insert-spark key label)))

(defun homun-stage-live-insert (s)
  "Hook of `homun-stage-render-functions': the sparklines of the scene S at the end
of the buffer."
  (when (member (homun-stage-scene-id s) homun-stage-live-scenes)
    (homun-stage-live--ensure)
    (goto-char (point-max))
    (insert "\n")
    (homun-stage-live--insert-sparks)))

;;; The clock

(defvar homun-stage-live-visible-function
  (lambda (buf) (when-let* ((w (get-buffer-window buf t))) (frame-visible-p (window-frame w))))
  "Non-nil for a strip buffer a visible window shows.")

(defun homun-stage-live--visible-p (buf) (funcall homun-stage-live-visible-function buf))

(defun homun-stage-live--refresh-sparks ()
  "Read the sparkline data and redraw the spans whose data changed, in the visible
strips."
  (setq homun-stage-live--spark-cache
        (mapcar (lambda (src) (cons (car src) (ignore-errors (funcall (nth 2 src))))) homun-stage-live-spark-sources))
  (dolist (buf homun-stage-live--buffers)
    (when (and (buffer-live-p buf) (homun-stage-live--visible-p buf))
      (with-current-buffer buf
        (dolist (sp homun-stage-live--sparks)
          (pcase-let* ((`(,key ,marker ,len ,_) sp)
                       (str (homun-stage-live--spark-string (or (alist-get key homun-stage-live--spark-cache) '(nil 1 nil)))))
            (unless (or (not (marker-position marker)) (equal-including-properties str (nth 3 sp)))
              (homun-stage-live--put marker len str)
              (setf (nth 3 sp) str))))))))

(defun homun-stage-live--tick (snap)
  "The clock client: step the rows of each visible strip that still animate.
Non-nil while one does; nil when none is visible, so the clock pauses."
  (let ((now (funcall homun-clock-time-function)) (any nil))
    (setq homun-stage-live--buffers (cl-delete-if-not #'buffer-live-p homun-stage-live--buffers))
    (when (> (- now homun-stage-live--spark-at) homun-stage-live-spark-refresh)
      (setq homun-stage-live--spark-at now)
      (run-with-idle-timer 0.05 nil #'homun-stage-live--refresh-sparks))
    (dolist (buf homun-stage-live--buffers)
      (when (homun-stage-live--visible-p buf)
        (with-current-buffer buf
          (setq homun-stage-live--active
                (cl-delete-if-not (lambda (st) (homun-stage-live--step st now snap)) homun-stage-live--active))
          (when homun-stage-live--active (setq any t)))))
    any))

(defun homun-stage-live--wake (&rest _)
  "Window change hook: a strip that became visible gets a frame."
  (when (and homun-stage-live--buffers (assq 'stage-live homun-clock--clients))
    (homun-clock-dirty 'stage-live)))

(add-hook 'window-configuration-change-hook #'homun-stage-live--wake)

;;; Sources: the work-map

(defvar homun-stage-live--work-rows nil "Rows of the work-map from its last sync.")
(defvar homun-stage-live--slots nil "Newest-last counts of running rows, one per sync.")
(declare-function claude-agent--select "claude-agent")
(declare-function homun-freeze-watch--read "homun-freeze-watch")

(defun homun-stage-live-work-refresh (items)
  "Note ITEMS, the (ID LABEL STATE) of the map: a changed set of unfinished rows
adds a point to the slots history."
  (let ((rows (cl-loop for (id label state) in items
                       unless (member state '("todo" "done")) collect (list id label state))))
    (unless (equal rows homun-stage-live--work-rows)
      (setq homun-stage-live--work-rows rows
            homun-stage-live--slots
            (last (append homun-stage-live--slots
                          (list (cl-count "running" rows :key #'caddr :test #'equal)))
                  homun-stage-live-spark-points)))))

(defun homun-stage-live--budget ()
  "(VALUES MAX SUFFIX) of the 5h plan usage over the newest samples (usage-db)."
  (let ((rows (claude-agent--select
               "select five_hour_used from samples where five_hour_used is not null order by ts desc limit 16")))
    (when rows (let ((v (nreverse (mapcar #'car rows)))) (list v 100.0 (format "%d%%" (round (car (last v)))))))))

(defun homun-stage-live--slots-data ()
  (list homun-stage-live--slots (max 4 (apply #'max 0 homun-stage-live--slots))
        (format "%d" (or (car (last homun-stage-live--slots)) 0))))

(defun homun-stage-live--stalls ()
  "(VALUES MAX SUFFIX): freeze stalls per four minutes over the last hour, from the
freeze watch."
  (when (require 'homun-freeze-watch nil t)
    (let* ((now (float-time)) (buckets (make-list 15 0)))
      (dolist (e (homun-freeze-watch--read))
        (let ((i (floor (- 14 (/ (- now (plist-get e :time)) 240)))))
          (when (<= 0 i 14) (cl-incf (nth i buckets)))))
      (list buckets (max 3 (apply #'max buckets)) (format "%d" (apply #'+ buckets))))))

(setq homun-stage-live-scenes '("work-map")
      homun-stage-live-spark-sources '((budget "5h budget" homun-stage-live--budget)
                                       (slots "slots" homun-stage-live--slots-data)
                                       (stalls "stalls 1h" homun-stage-live--stalls)))

;; Drop every advice an earlier load put on the sync, whatever its function object
(advice-mapc (lambda (f _) (advice-remove 'homun-stage-work-sync f)) 'homun-stage-work-sync)
(add-hook 'homun-stage-render-functions #'homun-stage-live-insert)

(provide 'homun-stage-live)
;;; homun-stage-live.el ends here
