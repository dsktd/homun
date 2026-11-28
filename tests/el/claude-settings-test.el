;;; claude-settings-test.el --- ERT for saving in claude-settings.el -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-settings-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'claude-settings)

(defvar claude-settings-test-a 1)
(defvar claude-settings-test-b 2)

(defmacro claude-settings-test--with-file (&rest body)
  (declare (indent 0))
  `(let* ((dir (make-temp-file "claude-settings" t))
          (claude-settings-file (expand-file-name "settings.eld" dir))
          (claude-settings--pending nil)
          (claude-settings--defaults nil)
          (claude-settings--save-timer nil))
     (unwind-protect
         (cl-letf (((symbol-function 'claude-settings--redraw) #'ignore))
           (setq-default claude-settings-test-a 1 claude-settings-test-b 2)
           ,@body)
       (delete-directory dir t))))

(ert-deftest claude-settings-flush-saves-every-pending-change ()
  (claude-settings-test--with-file
    (claude-settings-set 'claude-settings-test-a 10)
    (claude-settings-set 'claude-settings-test-b 20)
    (claude-settings--flush)
    (should (equal '((claude-settings-test-a . 10) (claude-settings-test-b . 20))
                   (claude-settings--saved)))
    (should-not claude-settings--pending)))

(ert-deftest claude-settings-flush-drops-a-reset ()
  (claude-settings-test--with-file
    (claude-settings-set 'claude-settings-test-a 10)
    (claude-settings-set 'claude-settings-test-b 20)
    (claude-settings--flush)
    (claude-settings-set 'claude-settings-test-a 1)
    (claude-settings--flush)
    (should (equal '((claude-settings-test-b . 20)) (claude-settings--saved)))))

(ert-deftest claude-settings-saved-reports-a-corrupt-file ()
  (claude-settings-test--with-file
    (with-temp-file claude-settings-file (insert "((a . 1"))
    (should-not (claude-settings--saved))))

(ert-deftest claude-settings-scene-has-a-control-and-reset-per-row ()
  (claude-settings-test--with-file
    (let* ((claude-settings-groups
            '(("Test" (claude-settings-test-a integer "A number." :min 0 :max 9 :step 1)
                      (claude-settings-test-b boolean "A flag."))))
           (root (claude-settings-scene)))
      (homun-stage-validate root)
      (should (equal (alist-get 'kind (car (homun-stage--find root "set-claude-settings-test-a"))) "slider"))
      (should (equal (alist-get 'kind (car (homun-stage--find root "set-claude-settings-test-b"))) "toggle"))
      ;; a control reports its value to the setting; a reset brings the default back
      (funcall (gethash "set-claude-settings-test-a" homun-stage-actions) 3.0)
      (should (eql (default-value 'claude-settings-test-a) 3))
      (funcall (gethash "reset-claude-settings-test-a" homun-stage-actions))
      (should (eql (default-value 'claude-settings-test-a) 1)))))
