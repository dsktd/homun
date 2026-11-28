;;; homun-version.el --- M-x homun-version: which Elisp, image revs and last update -*- lexical-binding: t -*-

(require 'subr-x)

(defvar homun-version)
(defvar claude-remote-live-version)
(defvar claude-remote-live-last)
(declare-function claude-update--rev "claude-update")
(declare-function claude-update--staged-rev "claude-update")

(defun homun-version-text ()
  "One line: the loaded Elisp's version and what is known about the image or the
last update.
On the desktop the Elisp comes from the running image (/opt/homun, no .git), so
its rev is the running image's rev; `homun-version' is set to it."
  (if (featurep 'claude-remote-live)
      (format "homun elisp %s, gateway %s, last update: %s" (or (bound-and-true-p homun-version) "unknown")
              (or claude-remote-live-version "unknown") (or claude-remote-live-last "unknown"))
    (let* ((short (lambda (r) (if r (substring r 0 (min 8 (length r))) "unknown")))
           (running (and (fboundp 'claude-update--rev) (claude-update--rev "running-rev")))
           (staged (and (fboundp 'claude-update--staged-rev) (claude-update--staged-rev))))
      (unless (bound-and-true-p homun-version) (setq homun-version (and running (funcall short running))))
      (format "homun elisp %s, running image %s, staged image %s" (or homun-version "unknown")
              (funcall short running) (if staged (funcall short staged) "none")))))

;;;###autoload
(defun homun-version (&optional copy)
  "Show the version text in the echo area and *Messages*; with prefix COPY, kill it
too."
  (interactive "P")
  (let ((text (homun-version-text)))
    (message "%s" text)
    (when copy (kill-new text))
    text))

(provide 'homun-version)
