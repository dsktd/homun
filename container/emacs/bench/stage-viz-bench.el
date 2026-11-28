;;; stage-viz-bench.el --- one scene of 20 expr-driven shapes through the real Stage renderer  -*- lexical-binding: t; -*-
;; Load in the live daemon; the p50 and p95 in ms are in `homun-stage-viz-bench-p50' and -p95..
(defvar homun-stage-viz-bench-p50 nil)
(defvar homun-stage-viz-bench-p95 nil)
(require 'homun-stage)
(let* ((kids (cl-loop for i below 20 collect
  `((type . "shape") (kind . "circle") (x . ((expr . ("+" 40 ("*" 28 "i"))))) (y . ((expr . ("+" 180 ("*" 120 ("sin" ("+" ("*" "t" 3) "i"))))))) (r . 8) (fill . "accent"))))
       (scene `((type . "layer") (children . ,kids))) ts)
  (dotimes (k 300)
    (let ((s (float-time))) (let ((svg (homun-stage-svg scene 640))) (image-size (svg-image svg) t))
      (push (* 1000 (- (float-time) s)) ts)))
  (setq ts (sort ts #'<))
  (setq homun-stage-viz-bench-p50 (nth 150 ts) homun-stage-viz-bench-p95 (nth 285 ts)))
(provide 'stage-viz-bench)
