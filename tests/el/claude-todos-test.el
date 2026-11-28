;;; claude-todos-test.el --- Tests for the clean todos view -*- lexical-binding: t; -*-
(require 'ert)
(require 'claude-todos)

(defconst claude-todos-test--org
  "* Agents
** STRT Live one
:PROPERTIES:
:ID: agent-aaa
:AGENT: [[homun-agent:aaa]]
:END:
** DONE Old one
:PROPERTIES:
:ID: agent-bbb
:AGENT: [[homun-agent:bbb]]
:END:
- done, agent bbb: a long report
")

(defun claude-todos-test--view (source)
  "A rendered view of SOURCE."
  (let ((view (generate-new-buffer " *todos view*")))
    (with-current-buffer view
      (claude-todos-view-mode)
      (setq claude-todos--source source)
      (claude-todos--render view))
    view))

(ert-deftest claude-todos-view-folds-to-headings ()
  (with-temp-buffer
    (insert claude-todos-test--org)
    (let ((view (claude-todos-test--view (current-buffer))))
      (unwind-protect
          (with-current-buffer view
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "STRT Live one" text))
              (should (string-match-p "Done (1)" text)))
            (goto-char (point-min)) (search-forward "Live one")
            (should (org-fold-folded-p (line-end-position)))
            (goto-char (point-min))
            (search-forward "Old one")
            (should (equal "[[homun-agent:bbb]]" (org-entry-get nil "AGENT")))
            ;; Done is folded, and a redraw keeps an unfolded one open
            (should (org-fold-folded-p (point)))
            (goto-char (point-min)) (search-forward "Done (1)")
            (org-fold-subtree nil)
            (claude-todos--render view)
            (goto-char (point-min)) (search-forward "Done (1)")
            (should-not (org-fold-folded-p (line-end-position))))
        (kill-buffer view)))))

(provide 'claude-todos-test)
