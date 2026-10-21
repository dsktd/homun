;;; claude-test.el --- ERT for claude-browse-url -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'dbus)
(defvar claude-service-dir (make-temp-file "svc" t))
(load (expand-file-name "claude.el" (file-name-directory (locate-library "claude-agent"))) nil t)

(ert-deftest claude-browse-url-allowed-scheme-calls-portal ()
  (let (args)
    (cl-letf (((symbol-function 'dbus-call-method)
               (lambda (&rest a) (setq args a))))
      (claude-browse-url "https://example.org/")
      (should (member "https://example.org/" args))
      (should (equal (nth 4 args) "OpenURI")))))

(ert-deftest claude-browse-url-refuses-file ()
  (let (called)
    (cl-letf (((symbol-function 'dbus-call-method)
               (lambda (&rest _) (setq called t))))
      (claude-browse-url "file:///etc/passwd")
      (should-not called))))

(ert-deftest claude-browse-url-dbus-error-copies-url ()
  (let ((kill-ring nil))
    (cl-letf (((symbol-function 'dbus-call-method)
               (lambda (&rest _) (signal 'dbus-error '("no bus")))))
      (claude-browse-url "https://example.org/x")
      (should (equal (car kill-ring) "https://example.org/x")))))
