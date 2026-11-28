;;; claude-remote-fonts-test.el --- ERT for the phone's font install -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/claude-remote-fonts-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'claude-remote)

(defun claude-remote-fonts-test--frame (name body)
  (format "%s %s %d\n%s\n" (secure-hash 'sha256 body) name (length body) body))

(ert-deftest claude-remote-fonts-frames-install-only-changes ()
  (let* ((dir (make-temp-file "fonts" t))
         (body (concat (claude-remote-fonts-test--frame "A.ttf" "aa\nbb")
                       (claude-remote-fonts-test--frame "B.ttf" "cc")))
         (frames (claude-remote--font-frames body)))
    (unwind-protect
        (progn
          (should (equal (mapcar #'cadr frames) '("A.ttf" "B.ttf")))
          (should (equal (cddr (car frames)) "aa\nbb"))
          (should (equal (claude-remote--font-install frames dir) '("A.ttf" "B.ttf")))
          (should-not (claude-remote--font-install frames dir))
          (write-region "old" nil (expand-file-name "B.ttf" dir) nil 'silent)
          (should (equal (claude-remote--font-install frames dir) '("B.ttf"))))
      (delete-directory dir t))))

(ert-deftest claude-remote-glyphs-all-listed ()
  "Every non-ASCII glyph of the phone UI is mapped or known to be covered."
  (let ((dir (expand-file-name "container/emacs/" (locate-dominating-file default-directory "container")))
        (known (concat claude-remote-glyph-ok (mapconcat (lambda (m) (string (car m))) claude-remote-glyph-map "")
                         (mapconcat (lambda (m) (string (car m))) claude-remote-marker-map "")))
        unknown)
    (dolist (f (append (directory-files dir t "\\`claude-\\(remote.*\\|phone\\|compose\\|transcript.*\\)\\.el\\'")
                       (directory-files (concat dir "widgetry") t "\\.el\\'")
                       (list (concat dir "homun-menu.el"))))
      (with-temp-buffer
        (insert-file-contents f)
        (goto-char (point-min))
        (while (re-search-forward "[^\0-\177]" nil t)
          (unless (seq-contains-p known (char-before))
            (cl-pushnew (string (char-before)) unknown :test #'equal)))))
    (should-not unknown)))

(ert-deftest claude-remote-glyphs-install-sets-display-table ()
  (let ((standard-display-table nil))
    (claude-remote-glyphs-install)
    (should (equal (aref standard-display-table ?✎) [?»]))))

(ert-deftest claude-remote-markers-displayable ()
  "Each marker emoji has a display-table look-alike the phone's fonts draw."
  (let ((standard-display-table nil))
    (claude-remote-glyphs-install)
    (pcase-dolist (`(,from ,to ,_) claude-remote-marker-map)
      (should (vectorp (aref standard-display-table from)))
      (should (seq-contains-p claude-remote-glyph-ok to)))))
