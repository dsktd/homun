;;; homun-compile-test.el --- ERT for homun-compile.el -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/homun-compile-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'homun-compile)

(defun homun-compile-test--run (command)
  "Run COMMAND in /tmp; return (NAME OUTPUT STATUS) once its status file exists."
  (let* ((homun-compile-dir (file-name-as-directory (make-temp-file "hc" t)))
         (id (format "t%d" (random 100000)))
         (name (homun-compile-start "/tmp" command id))
         (status (expand-file-name (concat id ".status") homun-compile-dir))
         (n 0))
    (while (and (not (file-exists-p status)) (< (cl-incf n) 100))
      (accept-process-output nil 0.1))
    (list name
          (with-temp-buffer (insert-file-contents (expand-file-name (concat id ".out") homun-compile-dir))
                            (buffer-string))
          (string-to-number (with-temp-buffer (insert-file-contents status) (buffer-string))))))

(ert-deftest homun-compile-status-and-output ()
  (let ((r (homun-compile-test--run "echo hello; exit 3")))
    (should (string-prefix-p "*compile: tmp: echo hello; exit 3" (nth 0 r)))
    (should (string-match-p "hello" (nth 1 r)))
    (should (= 3 (nth 2 r)))
    (should (= 0 (nth 2 (homun-compile-test--run "true"))))
    (should (null (get-buffer-window (nth 0 r) t)))))

(ert-deftest homun-compile-keeps-newest-twenty ()
  (let ((homun-compile-keep 2))
    (dotimes (_ 4) (homun-compile-test--run "true"))
    (accept-process-output nil 0.2)
    (should (= 2 (length (seq-filter (lambda (b) (buffer-local-value 'homun-compile--id b))
                                     (buffer-list)))))))

(ert-deftest homun-compile-refuses-bad-input ()
  (should-error (homun-compile-start "/nonexistent-dir" "true" "x"))
  (should-error (homun-compile-start "/tmp" "true" "../x")))

(defun homun-compile-test--wait (id)
  "The result of run ID once it is done."
  (let ((n 0) r)
    (while (and (not (eq t (plist-get (setq r (homun-compile-result id)) :done))) (< (cl-incf n) 300))
      (accept-process-output nil 0.1))
    r))

(defun homun-compile-test--checkout (name text)
  "A fake git checkout under ~/claude holding NAME with TEXT; return the file."
  (let* ((dir (make-temp-file (expand-file-name "~/claude/.homun-compile-test-") t))
         (file (expand-file-name name dir)))
    (make-directory (expand-file-name ".git" dir))
    (with-temp-file file (insert text))
    file))

(ert-deftest homun-compile-ert-run-and-check ()
  (let* ((homun-compile-dir (file-name-as-directory (make-temp-file "hc" t)))
         (file (homun-compile-test--checkout
                "probe-test.el"
                ";;; probe-test.el -*- lexical-binding: t -*-\n(require 'ert)\n(ert-deftest probe-a () (should t))\n(ert-deftest probe-b () (should nil))\n(defun probe-c () (probe-undefined-fn))\n")))
    (unwind-protect
        (let ((r (homun-compile-test--wait (homun-compile-ert file "probe-a"))))
          (should (= 0 (plist-get r :status)))
          (should (seq-some (lambda (l) (string-match-p "Ran 1 test" l)) (plist-get r :summary)))
          (setq r (homun-compile-test--wait (homun-compile-ert file ".")))
          (should (/= 0 (plist-get r :status)))
          (should (seq-some (lambda (l) (string-match-p "unexpected" l)) (plist-get r :summary)))
          (setq r (homun-compile-test--wait (homun-compile-check file)))
          (should (seq-some (lambda (l) (string-match-p "Warning.*probe-undefined-fn" l)) (plist-get r :summary)))
          (should-not (file-exists-p (concat file "c"))))
      (delete-directory (file-name-directory file) t))))

(ert-deftest homun-compile-batch-refuses ()
  (should-error (homun-compile-ert "/etc/hosts" "."))
  (should-error (homun-compile-ert (expand-file-name "~/claude/CLAUDE.md") "."))
  (let ((file (homun-compile-test--checkout "x.el" "")))
    (unwind-protect (should-error (homun-compile-ert file "(eval-bad)"))
      (delete-directory (file-name-directory file) t)))
  (should-error (homun-compile-result "../x"))
  (should (eq :json-false (plist-get (homun-compile-result "never-ran") :done))))
