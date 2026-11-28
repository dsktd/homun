;;; homun-version-test.el --- ERT for homun-version -*- lexical-binding: t -*-
(require 'ert)
(require 'homun-version)

(ert-deftest homun-version-unknowns-and-copy ()
  (let ((homun-version nil) (kill-ring nil))
    (cl-letf (((symbol-function 'claude-update--staged-rev) (lambda () nil))
              ((symbol-function 'claude-update--rev) (lambda (_) "abc1234def")))
      (let ((text (homun-version t)))
        (should (string-match-p "elisp abc1234d, running image abc1234d, staged image none" text))
        (should (equal text (car kill-ring)))))))
