;;; claude-remote-swipe-touch-test.el --- ERT: taps and drags pass through the swipe watcher untouched -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -L container/emacs/widgetry -l tests/el/claude-remote-swipe-touch-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(require 'claude-remote-swipe)

(defun claude-remote-swipe-touch-test--run (from to active)
  "Play begin, update and end from FROM to TO through the advised handler.
Returns (SWIPES EVENTS-THE-ORIGINAL-SAW REGION-ACTIVE EVENTS-PLAYED)."
  (let* (swipes seen events
         (claude-remote-swipe--start nil)
         (claude-remote-swipe-active-function (lambda (_w) active))
         (claude-remote-swipe-function (lambda (d _w) (push d swipes))))
    (cl-letf (((symbol-function 'run-at-time) (lambda (_a _b f &rest _) (funcall f)))
              ((symbol-function 'window-pixel-width) (lambda (&rest _) 1000))
              ((symbol-function 'touch-screen-handle-touch) (lambda (e &rest _) (push e seen) 'orig)))
      (advice-add 'touch-screen-handle-touch :before #'claude-remote-swipe--advice)
      (unwind-protect
          (with-temp-buffer
            (insert (make-string 100 ?x))
            (set-window-buffer (selected-window) (current-buffer))
            (deactivate-mark)
            (let ((p0 (list (selected-window) nil from 0)) (p1 (list (selected-window) nil to 0)))
              (setq events `((touchscreen-begin (1 . ,p0)) (touchscreen-update ((1 . ,p1)))
                             (touchscreen-end (1 . ,p1))))
              (dolist (e events) (should (eq 'orig (touch-screen-handle-touch e nil))))
              (list swipes (nreverse seen) (region-active-p) events)))
        (advice-remove 'touch-screen-handle-touch #'claude-remote-swipe--advice)))))

(ert-deftest claude-remote-swipe-tap-is-not-a-swipe-and-leaves-no-region ()
  (let ((r (claude-remote-swipe-touch-test--run '(100 . 100) '(102 . 101) t)))
    (should-not (nth 0 r))
    (should (equal (nth 1 r) (nth 3 r)))
    (should-not (nth 2 r))))

(ert-deftest claude-remote-swipe-short-drag-is-no-swipe ()
  (let ((r (claude-remote-swipe-touch-test--run '(100 . 100) '(140 . 100) t)))
    (should-not (nth 0 r))
    (should (equal (nth 1 r) (nth 3 r)))
    (should-not (nth 2 r))))

(ert-deftest claude-remote-swipe-long-flat-drag-is-one-swipe ()
  (let ((r (claude-remote-swipe-touch-test--run '(400 . 100) '(50 . 105) t)))
    (should (equal '(left) (nth 0 r)))
    (should (equal (nth 1 r) (nth 3 r)))
    (should-not (nth 2 r))))

(ert-deftest claude-remote-swipe-ignored-outside-the-detail ()
  (let ((r (claude-remote-swipe-touch-test--run '(400 . 100) '(50 . 105) nil)))
    (should-not (nth 0 r))
    (should (equal (nth 1 r) (nth 3 r)))))
