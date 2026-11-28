;;; homun-clock-test.el --- ERT for homun-clock -*- lexical-binding: t -*-
(require 'ert)
(require 'homun-clock)

(defmacro homun-clock-test--with (&rest body)
  `(let ((homun-clock--clients nil) (homun-clock--timer nil) (homun-clock--level 0)
         (homun-clock--fast 0) (homun-clock--unfocused-since nil) (homun-clock--wanted nil)
         (homun-clock-slow-hook nil) (homun-clock--periods nil)
         (homun-clock-visible-function (lambda () t))
         (homun-clock-focused-function (lambda () t)))
     (unwind-protect (progn ,@body) (homun-clock--stop))))

(ert-deftest homun-clock-idle-runs-no-timer ()
  (homun-clock-test--with
   (should (= 0 (homun-clock-timers)))
   (homun-clock-register 'a (lambda (_) nil))
   (should (= 1 (homun-clock-timers)))
   (homun-clock-tick)
   (should (= 0 (homun-clock-timers)))))

(ert-deftest homun-clock-animating-keeps-one-timer ()
  (homun-clock-test--with
   (homun-clock-register 'a (lambda (_) t))
   (homun-clock-register 'b (lambda (_) t))
   (homun-clock-tick)
   (should (= 1 (homun-clock-timers)))))

(ert-deftest homun-clock-over-budget-leads-to-slow ()
  (homun-clock-test--with
   (let* ((now 0.0) (slow nil)
          (homun-clock-time-function (lambda () (setq now (+ now 0.01)))))
     (add-hook 'homun-clock-slow-hook (lambda (_) (setq slow t)) nil t)
     (homun-clock-register 'a (lambda (_) t))
     (homun-clock-tick)
     (should (= 1 homun-clock--level))
     (should (= 15.0 (homun-clock-fps)))
     (homun-clock-tick)
     (should (= 2 homun-clock--level))
     (should-not slow)
     (homun-clock-tick)
     (should slow))))

(ert-deftest homun-clock-snap-passed-at-level-two ()
  (homun-clock-test--with
   (let (seen)
     (setq homun-clock--level 2)
     (homun-clock-register 'a (lambda (snap) (push snap seen) nil))
     (homun-clock-tick)
     (should (equal seen '(t))))))

(ert-deftest homun-clock-pauses-hidden-and-unfocused ()
  (homun-clock-test--with
   (let ((now 0.0) (vis t))
     (let ((homun-clock-time-function (lambda () now))
           (homun-clock-visible-function (lambda () vis))
           (homun-clock-focused-function (lambda () nil)))
       (homun-clock-register 'a (lambda (_) t))
       (should (= 1 (homun-clock-timers)))
       (setq now 31.0)
       (homun-clock-tick)
       (should (= 0 (homun-clock-timers)))
       (setq now 0.0 homun-clock--unfocused-since nil vis nil)
       (homun-clock-dirty)
       (should (= 0 (homun-clock-timers)))))))

(ert-deftest homun-clock-slow-clients-slow-the-timer ()
  (homun-clock-test--with
   (homun-clock-register 'a (lambda (_) t) 5)
   (should (= 5 (timer--repeat-delay homun-clock--timer)))
   (homun-clock-register 'b (lambda (_) t))
   (should (< (timer--repeat-delay homun-clock--timer) 0.1))))
