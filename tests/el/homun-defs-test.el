;;; homun-defs-test.el --- No function is defined twice in the cockpit Elisp -*- lexical-binding: t -*-
;; emacs --batch -l tests/el/homun-defs-test.el -f ert-run-tests-batch-and-exit

;; A second top-level defun of the same name silently replaces the first: that is how the
;; board's clock watch became a file watch called on every draw (a growing timer storm).

(require 'ert)
(require 'cl-lib)

(defvar homun-defs-test--dir
  (expand-file-name "../../container/emacs/" (file-name-directory (or load-file-name buffer-file-name))))

(defvar homun-defs-test--stand-ins '(homun-rpc)
  "Names a file defines on purpose as a stand-in until the real one loads.")

(defun homun-defs-test--names (file)
  "The top-level defun, defmacro and defsubst names of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (let (names)
      (condition-case nil
          (while t
            (let ((form (read (current-buffer))))
              (when (and (consp form) (memq (car form) '(defun defmacro defsubst cl-defun)))
                (push (cadr form) names))))
        (end-of-file nil))
      names)))

(ert-deftest homun-defs-no-function-defined-twice ()
  (let ((seen (make-hash-table)) dups)
    (dolist (file (directory-files homun-defs-test--dir t "\\.el\\'"))
      (dolist (name (homun-defs-test--names file))
        (let ((where (file-name-nondirectory file)))
          (when (and (gethash name seen) (not (memq name homun-defs-test--stand-ins))) (push (list name (gethash name seen) where) dups))
          (puthash name where seen))))
    (should-not dups)))
