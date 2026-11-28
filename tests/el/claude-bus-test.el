;;; claude-bus-test.el --- ERT for the cockpit's view of Cal's words on the bus -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-bus-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'claude-bus)

(defmacro claude-bus-test--box (&rest body)
  `(let* ((root (make-temp-file "bus" t))
          (claude-bus-dir root)
          (claude-bus-device "host")
          (claude-bus-transport nil))
     (unwind-protect (progn ,@body) (delete-directory root t))))

(defun claude-bus-test--mark (kind id &optional age)
  (let ((f (expand-file-name id (claude-bus-user-dir 'manager kind))))
    (make-directory (file-name-directory f) t)
    (write-region "" nil f nil 'silent)
    (when age (set-file-times f (time-subtract nil age)))))

(ert-deftest claude-bus-user-markers-decide-where ()
  (claude-bus-test--box
   (let ((a (claude-bus-user-write 'manager "one"))
         (b (progn (sleep-for 0.001) (claude-bus-user-write 'manager "two")))
         (c (progn (sleep-for 0.001) (claude-bus-user-write 'manager "three"))))
     (should (equal (claude-bus-user-names 'manager) (list a b c)))
     (claude-bus-test--mark "sending" a)
     (claude-bus-test--mark "claimed" b)
     (should (eq (claude-bus-user-where 'manager a) 'sending))
     (should (eq (claude-bus-user-where 'manager b) 'claimed))
     (should (eq (claude-bus-user-where 'manager c) 'queued))
     (should (equal (claude-bus-user-counts 'manager) '(:queued 1 :sending 1 :failed 0 :paused nil)))
     ;; the box keeps the files: the reader only marks
     (should (file-exists-p (expand-file-name b (claude-bus-user-dir 'manager)))))))

(ert-deftest claude-bus-user-retry-drops-the-failed-marker ()
  (claude-bus-test--box
   (let ((a (claude-bus-user-write 'manager "one")))
     (claude-bus-test--mark "failed" a)
     (claude-bus-user-pause 'manager t)
     (should (plist-get (claude-bus-user-counts 'manager) :paused))
     (should (eq (claude-bus-user-where 'manager a) 'failed))
     (claude-bus-user-retry 'manager a)
     (should (eq (claude-bus-user-where 'manager a) 'queued))
     (claude-bus-user-drop 'manager a)
     (should-not (claude-bus-user-where 'manager a)))))

(ert-deftest claude-bus-user-withdraw-only-before-a-claim ()
  (claude-bus-test--box
   (let ((a (claude-bus-user-write 'manager "one"))
         (b (progn (sleep-for 0.001) (claude-bus-user-write 'manager "two"))))
     (claude-bus-test--mark "sending" b)
     (should (eq t (claude-bus-user-withdraw 'manager a)))
     (should-not (claude-bus-user-where 'manager a))
     (should-not (claude-bus-user-withdraw 'manager a))
     (should (eq 'claimed (claude-bus-user-withdraw 'manager b)))
     (should (file-exists-p (expand-file-name b (claude-bus-user-dir 'manager)))))))

(ert-deftest claude-bus-user-prune-removes-delivered ()
  (claude-bus-test--box
   (let ((old (claude-bus-user-write 'manager "old"))
         (new (progn (sleep-for 0.001) (claude-bus-user-write 'manager "new"))))
     (claude-bus-test--mark "claimed" old (* 2 claude-bus-user-keep))
     (claude-bus-test--mark "claimed" new)
     (claude-bus-user-prune 'manager)
     (should-not (file-exists-p (expand-file-name old (claude-bus-user-dir 'manager))))
     (should-not (claude-bus-user-where 'manager old))
     (should (eq (claude-bus-user-where 'manager new) 'claimed)))))

;;; claude-bus-test.el ends here
