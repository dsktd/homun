;;; homun-scroll-test.el --- ERT for smooth scrolling -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/homun-scroll-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'homun-scroll)

(defun homun-scroll-test--apply (value)
  (let ((homun-smooth-scroll value)) (homun-smooth-scroll-apply)))

(ert-deftest homun-scroll-desktop-on-phone-off ()
  (let ((system-type 'gnu/linux))
    (homun-scroll-test--apply t)
    (should pixel-scroll-precision-mode)
    (should pixel-scroll-precision-use-momentum)
    (should (<= pixel-scroll-precision-interpolation-between-scroll 0.008))
    (should (eq (lookup-key global-map [remap scroll-up-command]) 'pixel-scroll-interpolate-down))
    (homun-scroll-test--apply nil)
    (should-not pixel-scroll-precision-mode))
  (let ((system-type 'android))
    (homun-scroll-test--apply t)
    (should-not pixel-scroll-precision-mode)
    (should-not (lookup-key global-map [remap scroll-up-command]))))

(provide 'homun-scroll-test)
