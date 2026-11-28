;;; homun-stage-anim.el --- Tweens of animate ops, driven by homun-clock -*- lexical-binding: t -*-

;; A patch op {"path":"/g/nodes/mgr/x","animate":{"to":N,"ms":400,"ease":"out"}} stores `to' at
;; once (the scene is always the truth), and also starts a tween: until it ends, the Stage
;; draws `homun-stage-anim-view' of the scene, its animated numbers part-way from the old
;; value.  One `homun-clock' client advances every tween; a snapping frame (the clock over
;; budget) ends them all.  A non-number, a missing old value and a stepper's `current' (an index) just snap.

;;; Code:

(require 'cl-lib)
(require 'homun-clock)
(require 'homun-expr)
(require 'homun-stage-store)

(defvar homun-stage-anim--tweens nil
  "Alist of scene id to its tweens, each (PATH FROM TO START SECONDS EASE).")

(defun homun-stage-anim--ease (name x)
  "X in 0..1 eased by NAME: linear in out inout (default inout)."
  (pcase name
    ("linear" x) ("in" (* x x)) ("out" (- 1 (* (- 1 x) (- 1 x))))
    (_ (homun-expr--ease x))))

(defun homun-stage-anim--cell (root path)
  "The alist cell holding the value at PATH (/node/field or /node/list/item/field)
of ROOT."
  (let* ((segs (split-string (substring path 1) "/")) (hit (homun-stage--find root (car segs))))
    (when-let* ((node (car hit)))
      (pcase (length segs)
        (2 (assq (intern (cadr segs)) node))
        (4 (when-let* ((item (cl-find-if (lambda (x) (and (homun-stage--obj-p x) (equal (alist-get 'id x) (nth 2 segs))))
                                         (alist-get (intern (nth 1 segs)) node))))
             (assq (intern (nth 3 segs)) item)))))))

(defun homun-stage-anim-start (id old-root ops)
  "Start a tween for each animate op of OPS (applied to OLD-ROOT) of scene ID that
can tween."
  (dolist (op ops)
    (let ((a (alist-get 'animate op)) (path (alist-get 'path op)))
      (when (and a (stringp path) (numberp (alist-get 'ms a)) (> (alist-get 'ms a) 0)
                 (numberp (alist-get 'to a)) (not (string-suffix-p "/current" path)))
        (let ((from (cdr (ignore-errors (homun-stage-anim--cell old-root path)))))
          (when (numberp from)
            (setf (alist-get id homun-stage-anim--tweens nil nil #'equal)
                  (cons (list path from (alist-get 'to a) (funcall homun-clock-time-function)
                              (/ (alist-get 'ms a) 1000.0) (alist-get 'ease a))
                        (cl-remove path (alist-get id homun-stage-anim--tweens nil nil #'equal)
                                   :key #'car :test #'equal)))
            (homun-clock-register "stage-anim" #'homun-stage-anim--tick)))))))

(defun homun-stage-anim--value (tw now)
  (pcase-let ((`(,_ ,from ,to ,start ,secs ,ease) tw))
    (let ((x (min 1.0 (/ (- now start) secs))))
      (+ from (* (- to from) (homun-stage-anim--ease ease x))))))

(defun homun-stage-anim-active-p (id)
  "Non-nil while scene ID has a tween."
  (and (alist-get id homun-stage-anim--tweens nil nil #'equal) t))

(defun homun-stage-anim-view (id root)
  "ROOT, or a copy of it with the animated numbers of scene ID at their current
value."
  (if-let* ((tws (alist-get id homun-stage-anim--tweens nil nil #'equal)))
      (let ((copy (copy-tree root)) (now (funcall homun-clock-time-function)))
        (dolist (tw tws copy)
          (when-let* ((cell (homun-stage-anim--cell copy (car tw))))
            (setcdr cell (homun-stage-anim--value tw now)))))
    root))

(defun homun-stage-anim--tick (snap)
  "The clock client: redraw the scenes with tweens; end the finished ones (all when
SNAP)."
  (let ((now (funcall homun-clock-time-function)) (any nil) (old homun-stage-anim--tweens))
    (setq homun-stage-anim--tweens nil)
    (pcase-dolist (`(,id . ,tws) old)
      (let ((live (and (not snap) (cl-remove-if (lambda (tw) (>= (- now (nth 3 tw)) (nth 4 tw))) tws))))
        (when live (push (cons id live) homun-stage-anim--tweens) (setq any t))
        (when-let* ((s (gethash id homun-stage-scenes))) (homun-stage-render s))))
    any))

(provide 'homun-stage-anim)
;;; homun-stage-anim.el ends here
