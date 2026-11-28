;;; claude-agent-view-test.el --- ERT for claude-agent-view.el -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-agent-view-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'claude-agent-view)
(require 'claude-transcript)
(require 'claude-compose)

(defmacro claude-agent-view-test--with (&rest body)
  "Run BODY with two transcript buffers in one window; BODY sees WINDOW, MAIN, SUB, and a
compose stub log SHOWN."
  `(let* ((main (generate-new-buffer " main"))
          (sub (generate-new-buffer " sub"))
          (shown nil)
          (window (selected-window)))
     (unwind-protect
         (progn
           (set-window-buffer window main)
           (set-frame-parameter nil 'claude-agent-view nil)
           (cl-letf (((symbol-function 'claude-transcript-buffer) (lambda (_f) sub))
                     ((symbol-function 'claude-agent-view--window) (lambda () window))
                     ((symbol-function 'claude-compose--pair) (lambda () (push 'pair shown)))
                     ((symbol-function 'claude-compose--show) (lambda (r) (push (list 'show r) shown)))
                     ((symbol-function 'claude-compose--visible-routes) #'ignore)
                     ((symbol-function 'claude-compose-route-buffer) #'identity)
                     ((symbol-function 'claude-compose--route-for-file)
                      (lambda (f) (and (string-suffix-p "main.jsonl" f) 'manager))))
             (with-current-buffer main (setq-local claude-transcript--file "/s/main.jsonl"))
             ,@body))
       (set-frame-parameter nil 'claude-agent-view nil)
       (kill-buffer main) (kill-buffer sub))))

(ert-deftest claude-agent-view-open-and-leave ()
  (claude-agent-view-test--with
   (should (eq (claude-agent-view-state) 'main))
   (claude-agent-view-open "/s/subagents/agent-1.jsonl")
   (should (equal (claude-agent-view-state) '(viewing "/s/subagents/agent-1.jsonl")))
   (should (eq (window-buffer window) sub))
   (should (equal shown '(pair)))
   (setq shown nil)
   (claude-agent-view-leave)
   (should (eq (claude-agent-view-state) 'main))
   (should (eq (window-buffer window) main))
   (should (equal (cadr (assq 'show shown)) 'manager))))

(ert-deftest claude-agent-view-second-agent-keeps-first-previous ()
  (claude-agent-view-test--with
   (claude-agent-view-open "/s/subagents/agent-1.jsonl")
   (claude-agent-view-open "/s/subagents/agent-2.jsonl")
   (claude-agent-view-leave)
   (should (eq (window-buffer window) main))))

(ert-deftest claude-agent-view-chattable-keeps-compose ()
  (claude-agent-view-test--with
   (claude-agent-view-open "/s/main.jsonl")
   (should (equal shown '((show manager))))))

(ert-deftest claude-agent-view-quit-on-main-buries ()
  (claude-agent-view-test--with
   (let (buried)
     (cl-letf (((symbol-function 'bury-buffer) (lambda (&rest _) (setq buried t))))
       (claude-agent-view-quit))
     (should buried))))
