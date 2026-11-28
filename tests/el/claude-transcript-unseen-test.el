;;; claude-transcript-unseen-test.el --- ERT for the unseen message count -*- lexical-binding: t; -*-
;; emacs --batch -L container/emacs -l tests/el/claude-transcript-unseen-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'claude-transcript)

(defun claude-transcript-unseen-tests--entries ()
  "A stream of tool records around two messages."
  (list
   '((type . "user") (message . ((content . "hello"))))
   `((type . "assistant") (message . ((content . [((type . "thinking") (thinking . "x"))]))))
   `((type . "assistant") (message . ((content . [((type . "tool_use") (id . "t1") (name . "Bash") (input . ()))]))))
   `((type . "user") (message . ((content . [((type . "tool_result") (tool_use_id . "t1") (content . "ok"))]))))
   `((type . "assistant") (message . ((content . [((type . "text") (text . "done"))]))))))

(defun claude-transcript-unseen-tests--insert (entries)
  "Insert ENTRIES as if a window scrolled up showed the buffer; return the unseen count."
  (progn
    (cl-letf (((symbol-function 'get-buffer-window-list) (lambda (&rest _) (list (selected-window))))
              ((symbol-function 'claude-transcript--stuck-windows) (lambda (&rest _) nil))
              ((symbol-function 'homun-layout-point) #'ignore)
              ((symbol-function 'claude-transcript--append-entries) #'ignore)
              ((symbol-function 'claude-transcript-stream-erase) #'ignore)
              ((symbol-function 'claude-transcript-stream-landed) #'ignore)
              ((symbol-function 'claude-transcript--outbox-draw) #'ignore))
      (with-temp-buffer
        (claude-transcript--insert-entries entries)
        claude-transcript--unseen))))

(ert-deftest claude-transcript-unseen-counts-messages-not-tools ()
  (should (= 2 (claude-transcript--message-count (claude-transcript-unseen-tests--entries))))
  (should (= 2 (claude-transcript-unseen-tests--insert (claude-transcript-unseen-tests--entries)))))

(ert-deftest claude-transcript-unseen-replay-is-not-new ()
  (let ((claude-transcript--replaying t))
    (should (= 0 (claude-transcript-unseen-tests--insert (claude-transcript-unseen-tests--entries))))))

(ert-deftest claude-transcript-unseen-view-then-new ()
  (progn
    (cl-letf (((symbol-function 'get-buffer-window-list) (lambda (&rest _) (list (selected-window))))
              ((symbol-function 'claude-transcript--stuck-windows) (lambda (&rest _) (list (selected-window))))
              ((symbol-function 'homun-layout-tail) #'ignore))
      (with-temp-buffer
        (setq claude-transcript--unseen 5)
        (claude-transcript--keeping-windows 1 #'ignore)
        (should (= 0 claude-transcript--unseen)))))
  (should (= 1 (claude-transcript-unseen-tests--insert
                (last (claude-transcript-unseen-tests--entries))))))
