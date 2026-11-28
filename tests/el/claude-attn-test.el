;;; claude-attn-test.el --- ERT for the attention ladder -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-attn-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'claude-attn)

(defmacro claude-attn-test--box (presence &rest body)
  `(let* ((root (make-temp-file "attn" t))
          (claude-attn-dir (expand-file-name "a/" root))
          (claude-attn-push-dir (expand-file-name "push/" root))
          (claude-attn--held nil) (claude-attn--recent nil)
          (shown nil)
          (claude-attn-notify-function (lambda (s) (push s shown))))
     (cl-letf (((symbol-function 'claude-attn-presence) (lambda () ,presence)))
       (unwind-protect (progn ,@body) (delete-directory root t)))))

(ert-deftest claude-attn-levels-and-quiet-window ()
  (should (eq (claude-attn-level "🔺 down") 'interrupt))
  (should (eq (claude-attn-level "🔸 hm") 'nudge))
  (should (eq (claude-attn-level "fyi") 'ambient))
  (let ((claude-attn-quiet nil) (claude-attn-quiet-start 22) (claude-attn-quiet-end 7))
    (should-not (claude-attn-quiet-p 23)))
  (let ((claude-attn-quiet t) (claude-attn-quiet-start 22) (claude-attn-quiet-end 7))
    (should (claude-attn-quiet-p 23)) (should (claude-attn-quiet-p 3))
    (should-not (claude-attn-quiet-p 12)))
  (let ((claude-attn-quiet t) (claude-attn-quiet-start 0) (claude-attn-quiet-end 0))
    (should-not (claude-attn-quiet-p 3))))

(ert-deftest claude-attn-ladder-steps ()
  (should (eq (claude-attn-step 'interrupt 'desk nil) 'desk))
  (should (eq (claude-attn-step 'interrupt 'mobile nil) 'phone))
  (should (eq (claude-attn-step 'interrupt 'away nil) 'push))
  (should (eq (claude-attn-step 'interrupt 'away t) 'held))
  (should (eq (claude-attn-step 'nudge 'away nil) 'nudge)))

(ert-deftest claude-attn-away-pushes-and-every-event-is-logged ()
  (claude-attn-test--box 'away
    (should (eq (claude-attn-handle '(:from "m" :alarm "x" :msg "🔺 boom")) 'push))
    (should (eq (claude-attn-handle '(:msg "fyi")) 'ambient))
    (should (= 1 (length (directory-files claude-attn-push-dir nil "\\.json\\'"))))
    (should (= 2 (with-temp-buffer
                   (insert-file-contents (expand-file-name "log.jsonl" claude-attn-dir))
                   (count-lines (point-min) (point-max)))))))

(ert-deftest claude-attn-quiet-holds-then-releases ()
  (claude-attn-test--box 'away
    (let ((claude-attn-quiet t) (claude-attn-quiet-start 22) (claude-attn-quiet-end 7))
      (should (eq (claude-attn-handle '(:msg "🔺 boom") 23) 'held))
      (should-not (file-directory-p claude-attn-push-dir))
      (should-not (claude-attn-release 23))
      (should (= 1 (length claude-attn--held)))
      (let ((claude-attn-quiet nil))
        (should (= 1 (claude-attn-release 9))))
      (should-not claude-attn--held)
      (should (= 1 (length (directory-files claude-attn-push-dir nil "\\.json\\'")))))))

(ert-deftest claude-attn-desk-notifies-here ()
  (claude-attn-test--box 'desk
    (claude-attn-handle '(:msg "🔺 boom"))
    (should (equal shown '("🔺 boom")))))
