;;; bench.el --- Time widgetry button redraws -*- lexical-binding: t; -*-
;; Run: make bench.  Batch has no graphic frame, so `display-graphic-p' is
;; forced true and SVG is built as text (no rendering, no image cache use).

(require 'cl-lib)
(require 'widgetry-button)

(defvar bench--graphic nil)
(defvar bench-n (string-to-number (or (getenv "N") "1000")))

(defun bench--report (name thunk &optional n)
  (let* ((n (or n bench-n))
         (r (benchmark-run n (funcall thunk))))
    (princ (format "%-34s %8.4f ms  gc %3d (%.2f ms)\n" name
                   (* 1000 (/ (car r) n)) (nth 1 r) (* 1000 (nth 2 r))))))

(defun bench--button (args)
  (setq bench--graphic nil)
  (let ((w (apply #'widget-create 'widgetry-button args))) (widget-setup) (setq bench--graphic t) w))

(let ((real (symbol-function 'display-graphic-p)))
  (advice-add 'display-graphic-p :around
              (lambda (f &rest a) (or bench--graphic (apply f a)))))
(advice-add 'image-type-available-p :around
            (lambda (f &rest a) (or bench--graphic (apply f a))))
(require 'color)
(advice-add 'color-values :override
            (lambda (c &optional _frame)
              (if (string-match "\\`#\\([0-9a-fA-F]\\{2\\}\\)\\([0-9a-fA-F]\\{2\\}\\)\\([0-9a-fA-F]\\{2\\}\\)" c)
                  (mapcar (lambda (i) (* 257 (string-to-number (match-string i c) 16))) '(1 2 3))
                '(13000 13000 13000))))
(progn
  (with-temp-buffer
    (clrhash widgetry--images)
    (let* ((drag (bench--button '(:value " Drag " :style motion :confirm t)))
           (hold (bench--button '(:value " Hold " :style motion :confirm hold)))
           (press (bench--button '(:value " Press " :style motion)))
           (phase 0.0) (g 0.0))
      (bench--report "motion hover drag (varying)"
                     (lambda () (widget-put drag :motion (setq phase (mod (+ phase 0.0137) 1.0)))
                       (widgetry-redraw drag)))
      ;; Real hovers replay the same ~32 frames each time (1.3 s at 0.04 s).
      (let ((k 0))
        (bench--report "motion hover drag (32 frames, jittered)"
                       (lambda () (widget-put drag :motion (+ (/ (setq k (mod (1+ k) 32)) 32.0) (/ (random 1000) 1e6)))
                         (widgetry-redraw drag))))
      (bench--report "hold track (varying)"
                     (lambda () (widget-put hold :glow (cons (setq g (mod (+ g 0.0137) 1.0)) (* g 1.3)))
                       (widgetry-redraw hold)))
      (widget-put hold :glow nil)
      (bench--report "plain press (cached, same state)" (lambda () (widgetry-redraw press)))
      (let ((n 0))
        (bench--report "plain press (varying fill)"
                       (lambda () (widget-put press :fill (/ (cl-incf n) 100000.0))
                         (widgetry-redraw press))))
      (let ((parts (funcall (widget-get drag :parts) drag))
            (frame (selected-frame)) (n 0))
        (bench--report "  svg build only (uncached)"
                       (lambda () (widgetry--svg-draw (widgetry--metrics frame)
                                                      (mapcar (lambda (p) (list (car p) (widgetry--paint (nth 1 p) frame) (+ (or (nth 2 p) 0.0) (/ (cl-incf n) 1e5)) (and (nth 3 p) (widgetry--paint (nth 3 p) frame)) (nth 4 p))) parts))))
        (bench--report "  paint+key only"
                       (lambda () (mapcar (lambda (p) (widgetry--paint (nth 1 p) frame)) parts))))))
  ;; 20 buttons
  (with-temp-buffer
    (let ((ws (cl-loop repeat 20 collect (bench--button '(:value " Drag " :style motion :confirm t))))
          (i 0))
      (bench--report "20 buttons redraw all" (lambda () (dolist (w ws) (widget-put w :motion (/ (cl-incf i) 1e6)) (widgetry-redraw w))) 100)
      (bench--report "20 buttons one redraw" (lambda () (widget-put (car ws) :motion (/ (cl-incf i) 1e6)) (widgetry-redraw (car ws)))))))
