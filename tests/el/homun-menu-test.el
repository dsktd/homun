;;; homun-menu-test.el --- ERT for the ? menus -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/homun-menu-test.el -f ert-run-tests-batch-and-exit
(require 'ert)
(require 'claude-transcript)
(require 'claude-board)
(require 'claude-compose)

(ert-deftest homun-menu-bound ()
  (should (eq 'homun-menu-transcript (lookup-key claude-transcript-mode-map "?")))
  (should (eq 'homun-menu-board (lookup-key claude-board-mode-map "?")))
  (should (eq 'homun-menu-compose (lookup-key claude-compose-mode-map (kbd "C-c ?")))))

(ert-deftest homun-menu-commands-exist ()
  (dolist (menu '(homun-menu-transcript homun-menu-board homun-menu-compose))
    (should (commandp menu))))

(require 'homun-stage-store)
(require 'claude-phone)
(require 'claude-questions)

(ert-deftest homun-menu-stage-phone-questions-bound ()
  (should (eq 'homun-menu-stage (lookup-key homun-stage-mode-map "?")))
  (should (eq 'claude-questions-menu (lookup-key claude-questions-map (kbd "C-c ?"))))
  (dolist (menu '(homun-menu-stage homun-menu-doctor claude-questions-menu))
    (should (commandp menu))))

(require 'claude-remote-home)
(require 'claude-remote-report)

(ert-deftest homun-menu-suffixes-are-commands ()
  "Every suffix of every menu is defined or autoloaded, so opening a menu cannot fail on one."
  (dolist (menu '(homun-menu-transcript homun-menu-board homun-menu-compose homun-menu-stage
                  homun-menu-doctor))
    (dolist (cmd (let (out)
                   (named-let walk ((x (get menu 'transient--layout)))
                     (cond ((vectorp x) (mapc #'walk x))
                           ((consp x) (when (keywordp (cadr x)) (ignore))
                                      (when (plist-get (and (proper-list-p x) (cdr x)) :command)
                                        (push (plist-get (cdr x) :command) out))
                                      (mapc #'walk (and (proper-list-p x) x)))))
                   out))
      (unless (memq cmd '(homun-update))
        (should (fboundp cmd))))))

(ert-deftest claude-remote-report-debugger-never-waits ()
  "With the report wrapper in, an error or a `debug' call is recorded and returns."
  (let ((claude-remote-report--queue nil) (claude-remote-report--sigs (make-hash-table :test 'equal))
        (claude-remote-report--debugger (lambda (&rest _) (error "old debugger reached"))))
    (should-not (claude-remote-report--debugger-fn 'error '(error "x")))
    (should-not (claude-remote-report--debugger-fn 'debug))
    (let ((claude-remote-report--inside t))
      (should-not (claude-remote-report--debugger-fn 'error '(error "y"))))))
