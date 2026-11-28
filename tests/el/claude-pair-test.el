;;; claude-pair-test.el --- The phone's pairing line and bootstrap block -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'claude-pair)

(ert-deftest claude-pair-line-writes-and-runs-the-block ()
  "The line writes the block, with its configuration, into init.el once, and evaluates it."
  (let* ((dir (make-temp-file "pair" t))
         (user-init-file (expand-file-name "init.el" dir))
         (claude-pair--device "phone")
         (line (claude-pair-line "homun-pair:h.example:8443/abc123/s3cret/cafe"))
         (user-emacs-directory (file-name-as-directory dir)))
    (unwind-protect
        (cl-letf (((symbol-function 'url-retrieve-synchronously) (lambda (&rest _) nil))
                  ((symbol-function 'run-at-time) #'ignore))
          (dolist (_ '(1 2))            ; pairing again replaces the block
            (with-temp-buffer (insert line) (goto-char 1) (eval (read (current-buffer)) t)))
          (with-temp-buffer
            (insert-file-contents user-init-file)
            (should (string-prefix-p ";;; -*- lexical-binding: t -*-" (buffer-string)))
            (should (= 1 (how-many "^;; homun begin")))
            (should (search-forward "https://h.example:8443/cockpit-gateway/" nil t))
            (should (search-forward ":code \"abc123.s3cret\"" nil t))
            (should (search-forward "(homun-start)\n;; homun end" nil t)))
          (should (equal (plist-get homun-conf :pin) "cafe")))
      (delete-directory dir t))))

(provide 'claude-pair-test)

(ert-deftest claude-pair-block-reads-source-dir ()
  "The bootstrap block comes from `homun-cockpit-dir', not from where claude-pair was loaded."
  (let ((homun-cockpit-dir (file-name-as-directory (make-temp-file "cockpit" t))))
    (with-temp-file (expand-file-name "homun-init.el" homun-cockpit-dir) (insert "(setq homun-conf nil)\n"))
    (should (string-match-p "homun-conf '(:url \"https://h:1/cockpit-gateway/\""
                            (claude-pair--block "homun-pair:h:1/a/b/c")))))
