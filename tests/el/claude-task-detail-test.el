;;; claude-task-detail-test.el --- ERT for the board task detail -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -L container/emacs/widgetry -l tests/el/claude-task-detail-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'claude-task-detail)
(require 'claude-tracker)

(defconst claude-task-detail-test--org
  "#+TODO: TODO NEXT DOING WAIT | DONE DROP\n* repo\n** TODO Fix it :a:b:\n   :PROPERTIES:\n   :ID:       7\n   :END:\n   The body.\n")

(defmacro claude-task-detail-test--with-file (&rest body)
  `(let* ((file (make-temp-file "tracker" nil ".org"))
          (process-environment (cons (concat "TRACKER_FILE=" file) process-environment)))
     (unwind-protect
         (progn (with-temp-file file (insert claude-task-detail-test--org)) ,@body)
       (delete-file file))))

(ert-deftest claude-task-detail-id-from-description ()
  (should (= 272 (claude-task-detail-tracker-id '(:id "x" :desc "#272 board task detail"))))
  (should-not (claude-task-detail-tracker-id '(:id "x" :desc "no number"))))

(ert-deftest claude-task-detail-json-and-state ()
  (claude-task-detail-test--with-file
   (let ((item (claude-task-detail-parse (claude-task-detail-show-json 7))))
     (should (equal "Fix it" (plist-get item :title)))
     (should (equal "TODO" (plist-get item :state)))
     (should (equal '("a" "b") (plist-get item :tags)))
     (should (equal "The body." (plist-get item :body))))
   (claude-task-detail-set-state 7 "next")
   (should (equal "NEXT" (plist-get (claude-task-detail-parse (claude-task-detail-show-json 7)) :state)))
   (should-error (claude-task-detail-set-state 7 "bogus"))))

(ert-deftest claude-task-detail-renders-fields-and-pills ()
  (let (clicked)
    (with-temp-buffer
      (claude-task-detail-insert
       (list :tracker '(:id 7 :title "Fix it" :state "TODO" :priority "A" :tags ("a" "b")
                        :body "The body." :workspace "7-fix" :branches ("homun: t7")
                        :notes ((:time "[2026-11-27]" :text "a note")))
             :agent '(:title "agent" :kind "subagent" :state "running" :last "tool: Bash ls"))
       (list :back (lambda () (push 'back clicked)) :next (lambda () (push 'next clicked))
             :done #'ignore :drop #'ignore))
      (let ((text (buffer-string)))
        (dolist (want '("#7 " "Fix it" "TODO" "a b" "7-fix" "homun: t7" "The body." "a note"
                        "running" "tool: Bash ls" "Back" "Next" "Done" "Drop"))
          (should (string-match-p (regexp-quote want) text))))
      ;; Pills sit below their label, at the left edge
      (goto-char (point-min))
      (search-forward "Actions")
      (forward-line 1)
      (should (looking-at " Back "))
      (search-forward "Next")
      (get-text-property (1- (point)) 'keymap)
      (funcall (lookup-key (get-text-property (1- (point)) 'keymap) (kbd "RET")))
      (should (equal '(next) clicked)))))

(ert-deftest claude-task-detail-without-item-has-only-back ()
  (with-temp-buffer
    (claude-task-detail-insert (list :agent '(:title "agent" :state "done")) (list :back #'ignore))
    (should (string-match-p "No tracker item" (buffer-string)))
    (should (string-match-p "Back" (buffer-string)))
    (should-not (string-match-p "Drop" (buffer-string)))))

(provide 'claude-task-detail-test)
