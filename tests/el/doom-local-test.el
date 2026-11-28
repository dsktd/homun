;;; doom-local-test.el --- ERT for container/emacs/doom/local.el: SPC o c wins -*- lexical-binding: t -*-
;; emacs --batch -l tests/el/doom-local-test.el -f ert-run-tests-batch-and-exit

(require 'ert)

(defvar doom-leader-map (make-sparse-keymap))
(defvar doom-after-init-hook nil)

(defconst doom-local-test--root
  (file-name-directory (directory-file-name (file-name-directory (directory-file-name (file-name-directory load-file-name))))))

(ert-deftest doom-local-leader-key-wins-after-init ()
  "A user's own SPC o c, even one made after local.el loads, loses once Doom has started."
  (let ((src (expand-file-name "container/emacs/doom/local.el" doom-local-test--root)))
    (with-temp-buffer
      (insert-file-contents src)
      (goto-char (point-min))
      ;; Read local.el form by form, evaluating only the key binding part (the rest is Doom's)
      (condition-case nil
          (while t
            (let ((form (read (current-buffer))))
              (when (and (consp form) (string-match-p "claude-bind-homun-key-h" (format "%S" form)))
                (eval form t))))
        (end-of-file nil)))
    (should (fboundp 'claude-bind-homun-key-h))
    (define-key doom-leader-map (kbd "o c") #'ignore)
    (run-hooks 'doom-after-init-hook)
    (should (eq (lookup-key doom-leader-map (kbd "o c")) 'claude-homun))))
