;;; org-claude.el --- Org buffers the manager spawns for the user -*- lexical-binding: t -*-

;;; Commentary:

;; `org-claude-mode' is the major mode of every Org buffer the manager opens for the user
;; to work in: the question buffers of `claude-questions' first.  The
;; dashboard and the tasks buffer may move onto it later; what they share
;; goes here, what is theirs stays in their own file.
;;
;; The mode adds the TODO keywords of Homun's buffers (OPEN, STAGED, DONE, N/A),
;; turns on org-modern when it is installed, and leaves keys to the buffers
;; that use it.

;;; Code:

(require 'org)
(declare-function org-modern-mode "org-modern")

(defvar org-claude-todo-keywords '((sequence "OPEN" "STAGED" "|" "DONE" "N/A"))
  "The TODO keywords of a Homun buffer, whatever the file says.")

(defun org-claude-modern ()
  "Turn on `org-modern-mode' in this buffer when the package is installed."
  (when (require 'org-modern nil t)
    (org-modern-mode 1)))

(define-derived-mode org-claude-mode org-mode "Org-Claude"
  "Org for the buffers the manager opens for the user to work in."
  ;; Org reads the keywords from the file or the default value, never a
  ;; buffer-local one
  (let ((org-todo-keywords org-claude-todo-keywords))
    (org-set-regexps-and-options))
  (org-claude-modern))

(provide 'org-claude)
;;; org-claude.el ends here
