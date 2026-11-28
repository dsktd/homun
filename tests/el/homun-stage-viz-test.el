;;; homun-stage-viz-test.el --- ERT for graph timeline chart shape expr animate -*- lexical-binding: t -*-

(require 'ert)
(require 'json)
(require 'homun-stage)
(require 'homun-stage-store)

(defun homun-stage-viz-test--p (s) (homun-stage-validate (json-parse-string s :object-type 'alist :array-type 'list)))

(defun homun-stage-viz-test--field (s)
  (condition-case err (progn (homun-stage-viz-test--p s) nil) (homun-stage-invalid (cadr err))))

(ert-deftest homun-stage-viz-graph ()
  (let ((g (homun-stage-viz-test--p
            "{\"type\":\"graph\",\"nodes\":[{\"id\":\"pin\"},{\"id\":\"build\",\"label\":\"build image\"},{\"id\":\"mgr\",\"state\":\"active\"}],\"edges\":[[\"pin\",\"build\"],[\"build\",\"mgr\"]]}")))
    (should (equal (homun-stage-text g) "○ pin → build\n  ○ build image → mgr\n    ▸ mgr"))
    (should (equal (mapcar #'cdr (homun-stage--layers g)) '(0 1 2)))
    (should (eq 'svg (car (homun-stage-svg g 400)))))
  (should (equal (homun-stage-viz-test--field "{\"type\":\"graph\",\"nodes\":[{\"id\":\"a\"}],\"edges\":[[\"a\",\"z\"]]}")
                 "/edges/0"))
  ;; a cycle ends instead of looping
  (should (homun-stage-text (homun-stage-viz-test--p "{\"type\":\"graph\",\"nodes\":[{\"id\":\"a\"},{\"id\":\"b\"}],\"edges\":[[\"a\",\"b\"],[\"b\",\"a\"]]}"))))

(ert-deftest homun-stage-viz-timeline ()
  (let ((tl (homun-stage-viz-test--p "{\"type\":\"timeline\",\"events\":[{\"at\":2,\"label\":\"b\"},{\"at\":1,\"label\":\"a\"}]}")))
    (should (equal (homun-stage-text tl) "1 ● a\n2 ● b"))
    (should (eq 'svg (car (homun-stage-svg tl 300)))))
  (should (equal (homun-stage-viz-test--field "{\"type\":\"timeline\",\"events\":[{\"at\":1}]}") "/events")))

(ert-deftest homun-stage-viz-chart ()
  (let ((homun-stage-bindings (make-hash-table :test #'equal)))
    (should (equal (homun-stage-text (homun-stage-viz-test--p "{\"type\":\"chart\",\"kind\":\"spark\",\"data\":[0,1,2,3,4,5,6,7]}"))
                   "▁▂▃▄▅▆▇█"))
    (should (equal (homun-stage-text (homun-stage-viz-test--p "{\"type\":\"chart\",\"kind\":\"line\",\"data\":[1,3]}")) "▁█ 1…3"))
    (should (string-match-p "a ██████████████████████ 2\\|a █+ 2" (homun-stage-text (homun-stage-viz-test--p "{\"type\":\"chart\",\"kind\":\"bar\",\"labels\":[\"a\"],\"data\":[2]}"))))
    (should (equal (homun-stage-text (homun-stage-viz-test--p "{\"type\":\"chart\",\"kind\":\"hist\",\"bins\":2,\"data\":[1,1,1,9]}")) "█▃ 1…9"))
    (should (equal (homun-stage-text (homun-stage-viz-test--p "{\"type\":\"chart\",\"kind\":\"spark\",\"data\":{\"bind\":\"u.series\"}}")) "…"))
    (puthash "u.series" '(0 4) homun-stage-bindings)
    (should (equal (homun-stage-text (homun-stage-viz-test--p "{\"type\":\"chart\",\"kind\":\"spark\",\"data\":{\"bind\":\"u.series\"}}")) "▁█"))
    (dolist (k '("line" "bar" "hist" "spark"))
      (should (eq 'svg (car (homun-stage-svg (homun-stage-viz-test--p (format "{\"type\":\"chart\",\"kind\":\"%s\",\"data\":[1,2,3]}" k)) 300))))))
  (should (equal (homun-stage-viz-test--field "{\"type\":\"chart\",\"kind\":\"pie\",\"data\":[]}") "/kind")))

(ert-deftest homun-stage-viz-shape-and-expr ()
  (let* ((s (homun-stage-viz-test--p
             "{\"type\":\"layer\",\"children\":[
                {\"type\":\"shape\",\"kind\":\"circle\",\"x\":{\"expr\":[\"*\",\"i\",10]},\"y\":5,\"r\":{\"expr\":[\"+\",\"v\",2]},\"fill\":\"accent\"},
                {\"type\":\"shape\",\"kind\":\"rect\",\"x\":1,\"y\":1,\"w\":{\"expr\":[\"/\",\"w\",2]},\"h\":4},
                {\"type\":\"shape\",\"kind\":\"arrow\",\"x\":0,\"y\":0,\"x2\":20,\"y2\":10},
                {\"type\":\"shape\",\"kind\":\"polygon\",\"points\":[[0,0],[10,0],[5,9]]},
                {\"type\":\"shape\",\"kind\":\"path\",\"d\":\"M0 0 L5 5\"},
                {\"type\":\"shape\",\"kind\":\"text\",\"text\":\"hi\"}],\"vars\":{\"v\":3}}")))
    (let ((svg (homun-stage-svg s 200)))
      (should (eq 'svg (car svg)))
      (should (= 1 (length (dom-by-tag svg (quote circle))))))
    (should (equal (homun-stage-text (homun-stage-viz-test--p "{\"type\":\"shape\",\"kind\":\"text\",\"text\":\"hi\"}")) "hi")))
  (should (equal (homun-stage-viz-test--field "{\"type\":\"shape\",\"kind\":\"cube\"}") "/kind"))
  (should (equal (homun-stage-viz-test--field "{\"type\":\"shape\",\"kind\":\"circle\",\"r\":{\"expr\":[\"eval\",1]}}") "/r"))
  ;; the expression variables t dt i n w h are always bound
  (let ((env (homun-stage-env nil 100 50))) (should (equal (assoc "w" env) '("w" . 100)))))

(defun homun-stage-viz-test--rt (clock f)
  (let ((homun-clock-time-function (lambda () (car clock))) (homun-clock-focused-function (lambda () t))
        (homun-clock--clients nil) (homun-clock--timer nil) (homun-stage-anim--tweens nil))
    (unwind-protect (funcall f) (homun-clock--stop))))

(ert-deftest homun-stage-viz-animate-tweens ()
  (let* ((now (list 100.0))
         (root (homun-stage-viz-test--p "{\"type\":\"col\",\"children\":[{\"type\":\"meter\",\"id\":\"m\",\"value\":0}]}"))
         (ops (json-parse-string "[{\"path\":\"/m/value\",\"animate\":{\"to\":1,\"ms\":1000,\"ease\":\"linear\"}}]"
                                 :object-type 'alist :array-type 'list)))
    (homun-stage-viz-test--rt
     now
     (lambda ()
       (homun-stage-anim-start "sc" root ops)
       (should (homun-stage-anim-active-p "sc"))
       (should (= 1 (homun-clock-timers)))
       (setcar now 100.5)
       (should (< (abs (- 0.5 (alist-get 'value (car (homun-stage--find (homun-stage-anim-view "sc" root) "m"))))) 1e-6))
       (should (= 0 (alist-get 'value (car (homun-stage--find root "m"))))) ; the scene itself is untouched
       (setcar now 102.0)
       (should-not (homun-stage-anim--tick nil))
       (should-not (homun-stage-anim-active-p "sc"))
       ;; snap ends a tween at once
       (homun-stage-anim-start "sc" root ops)
       (should-not (homun-stage-anim--tick t))
       (should-not (homun-stage-anim-active-p "sc"))))))

(ert-deftest homun-stage-viz-animate-non-number-snaps ()
  (homun-stage-viz-test--rt
   (list 1.0)
   (lambda ()
     (homun-stage-anim-start "sc" (homun-stage-viz-test--p "{\"type\":\"text\",\"id\":\"t\",\"text\":\"a\"}")
                             '(((path . "/t/text") (animate (to . "b") (ms . 100)))))
     (should-not (homun-stage-anim-active-p "sc")))))

(provide 'homun-stage-viz-test)
