;;; stage-bench.el --- SVG cost gate for the Stage  -*- lexical-binding: t; -*-

;; Ten scenes of twenty animated SVG nodes, driven at 30 fps for a
;; fixed time.  Each frame builds one scene, rasterises it through
;; librsvg (`image-size' with PIXELS forces the decode) and records the
;; wall time.  A second pass renders all ten scenes per frame.  Nothing
;; is displayed; results go to `stage-bench-result' and, as JSON, to
;; `stage-bench-output' when set.

(require 'svg)
(require 'json)

(defvar stage-bench-output nil "File the JSON result is written to.")
(defvar stage-bench-result nil "The last result, an alist.")
(defvar stage-bench--timer nil)

(defun stage-bench--scene (scene tick)
  "An image of SCENE at TICK: twenty moving, recoloured nodes."
  (let ((svg (svg-create 640 360)))
    (svg-rectangle svg 0 0 640 360 :fill "#1e1e2e")
    (dotimes (i 20)
      (let* ((phase (+ (* tick 0.1) (* i 0.31) scene))
             (x (+ 40 (* 28 i)))
             (y (+ 180 (* 120 (sin phase)))))
        (svg-circle svg x y (+ 6 (* 4 (abs (cos phase))))
                    :fill (format "#%02x%02x%02x" (* 12 i) (mod (* 40 scene) 256)
                                  (truncate (* 255 (abs (sin phase))))))
        (svg-text svg (number-to-string i) :x x :y (- y 14)
                  :fill "#cdd6f4" :font-size 10)))
    (svg-image svg)))

(defun stage-bench--frame (scenes tick)
  "Render SCENES images at TICK; return milliseconds taken."
  (let ((start (float-time)))
    (dolist (s scenes)
      (let ((img (stage-bench--scene s tick)))
        (image-size img t)
        (image-flush img)))
    (* 1000 (- (float-time) start))))

(defun stage-bench--stats (times)
  "Count, p50, p95, max of TIMES in ms."
  (let* ((v (vconcat (sort (copy-sequence times) #'<)))
         (n (length v))
         (at (lambda (q) (aref v (min (1- n) (floor (* q n)))))))
    `((frames . ,n) (p50 . ,(funcall at 0.5)) (p95 . ,(funcall at 0.95))
      (max . ,(aref v (1- n))))))

(defun stage-bench-run (&optional seconds)
  "Run both passes for SECONDS each (10) at 30 fps, without blocking."
  (interactive)
  (when (and (fboundp 'native-comp-available-p) (native-comp-available-p))
    (dolist (f '(stage-bench--scene stage-bench--frame))
      (native-compile f)))
  (let* ((secs (or seconds 10)) (frames (* 30 secs))
         (pass '(one)) (tick 0) one all)
    (setq stage-bench-result nil)
    (setq stage-bench--timer
          (run-at-time
           0 (/ 1.0 30)
           (lambda ()
             (if (eq (car pass) 'one)
                 (push (stage-bench--frame (list (% tick 10)) tick) one)
               (push (stage-bench--frame (number-sequence 0 9) tick) all))
             (setq tick (1+ tick))
             (when (= tick frames)
               (if (eq (car pass) 'one)
                   (setq pass '(all) tick 0)
                 (cancel-timer stage-bench--timer)
                 (setq stage-bench-result
                       `((native . ,(subr-native-elisp-p
                                     (symbol-function 'stage-bench--scene)))
                         (emacs . ,emacs-version)
                         (one-scene . ,(stage-bench--stats one))
                         (ten-scenes . ,(stage-bench--stats all))))
                 (when stage-bench-output
                   (with-temp-file stage-bench-output
                     (insert (json-encode stage-bench-result)))))))))))

(provide 'stage-bench)
;;; stage-bench.el ends here
