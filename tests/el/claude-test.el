;;; claude-test.el --- ERT for claude-browse-url -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'dbus)
(defvar claude-service-dir (make-temp-file "svc" t))
(load (expand-file-name "claude.el" (file-name-directory (locate-library "claude-agent"))) nil t)

(ert-deftest claude-browse-url-allowed-scheme-calls-portal ()
  (let (args)
    (cl-letf (((symbol-function 'dbus-call-method-asynchronously)
               (lambda (&rest a) (setq args a))))
      (claude-browse-url "https://example.org/")
      (should (member "https://example.org/" args))
      (should (equal (nth 4 args) "OpenURI")))))

(ert-deftest claude-browse-url-refuses-file ()
  (let (called)
    (cl-letf (((symbol-function 'dbus-call-method-asynchronously)
               (lambda (&rest _) (setq called t))))
      (claude-browse-url "file:///etc/passwd")
      (should-not called))))

(ert-deftest claude-browse-url-dbus-error-copies-url ()
  (let ((kill-ring nil))
    (cl-letf (((symbol-function 'dbus-call-method-asynchronously)
               (lambda (&rest _) (signal 'dbus-error '("no bus")))))
      (claude-browse-url "https://example.org/x")
      (should (equal (car kill-ring) "https://example.org/x")))))

(ert-deftest claude-browse-url-no-answer-copies-url ()
  (let ((kill-ring nil))
    (cl-letf (((symbol-function 'dbus-call-method-asynchronously) #'ignore)
              ((symbol-function 'run-at-time) (lambda (_t _r f) (funcall f))))
      (claude-browse-url "https://example.org/y")
      (should (equal (car kill-ring) "https://example.org/y")))))

(ert-deftest claude-browse-url-answered-stays-quiet ()
  (let ((kill-ring nil) handler timer)
    (cl-letf (((symbol-function 'dbus-call-method-asynchronously)
               (lambda (&rest a) (setq handler (nth 5 a))))
              ((symbol-function 'run-at-time) (lambda (_t _r f) (setq timer f))))
      (claude-browse-url "https://example.org/z")
      (funcall handler "/req")
      (funcall timer)
      (should-not kill-ring))))

;;; claude-browse-url: stubbed dbus

(defmacro claude-test--browse (calls &rest body)
  "Run BODY with `dbus-call-method-asynchronously' stubbed: its errors are the
cars of CALLS, one per call; a call after that succeeds."
  `(let ((attempts 0) (inits 0) (noted nil) (kill-ring nil))
     (cl-letf (((symbol-function 'dbus-call-method-asynchronously)
                (lambda (&rest _)
                  (let ((e (nth attempts ,calls)))
                    (cl-incf attempts)
                    (when e (signal 'dbus-error (list e))))))
               ((symbol-function 'dbus-init-bus) (lambda (&rest _) (cl-incf inits)))
               ((symbol-function 'run-at-time) #'ignore)
               ((symbol-function 'claude-errwatch-record)
                (lambda (&rest a) (push a noted))))
       (let ((inhibit-message t)) ,@body))))

(ert-deftest claude-browse-url-reinits-the-bus-once-and-retries ()
  (claude-test--browse '("No connection to bus" nil)
    (claude-browse-url "https://example.org")
    (should (= inits 1))
    (should (= attempts 2))
    (should-not noted)))

(ert-deftest claude-browse-url-reports-and-counts-a-second-failure ()
  (claude-test--browse '("No connection to bus" "No connection to bus")
    (claude-browse-url "https://example.org")
    (should (= inits 1))
    (should (equal (car kill-ring) "https://example.org"))
    (should (equal (car (car noted)) "handled"))))

(ert-deftest claude-browse-url-other-errors-do-not-reinit ()
  (claude-test--browse '("Access denied")
    (claude-browse-url "https://example.org")
    (should (= inits 0))
    (should (= attempts 1))
    (should noted)))
