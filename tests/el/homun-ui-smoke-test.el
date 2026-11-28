;;; homun-ui-smoke-test.el --- stale badge, 40-column smoke render and a redraw timing check  -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'claude)
(require 'claude-transcript)
(require 'claude-board)
(require 'claude-compose)

(defconst homun-ui-smoke--fixture
  (expand-file-name "claude-transcript-fixture.jsonl"
                    (file-name-directory (or load-file-name buffer-file-name))))

;; format-mode-line returns "" in a batch frame, so the header's elements are evaluated here
(defun homun-ui-smoke--header-text (format)
  (mapconcat (lambda (e) (cond ((stringp e) e)
                               ((eq (car-safe e) :eval) (or (eval (cadr e) t) ""))))
             format ""))

(ert-deftest homun-ui-stale-badge ()
  (should-not (claude-stale-badge nil 60))
  (should-not (claude-stale-badge (current-time) 60))
  (should-not (claude-stale-badge (time-subtract (current-time) 600) nil))
  (let ((badge (claude-stale-badge (time-subtract (current-time) 600) 60)))
    (should (equal (substring-no-properties badge) " [stale 10m]"))
    (should (eq 'warning (get-text-property 1 'face badge))))
  (with-temp-buffer
    (setq claude-updated (time-subtract (current-time) 600) claude-stale-after 60)
    (should (string-match-p "stale" (homun-ui-smoke--header-text (claude-header "T" "h"))))
    (setq claude-stale-after nil)
    (should-not (string-match-p "stale" (homun-ui-smoke--header-text (claude-header "T" "h"))))))

(defun homun-ui-smoke--narrow (buffer)
  "Show BUFFER in a window 40 columns wide, draw it, and return the header line text."
  (save-window-excursion
    (delete-other-windows)
    (set-window-buffer (selected-window) buffer)
    (let ((window (split-window nil 40 'left)))
      (set-window-buffer window buffer)
      (should (<= (window-body-width window) 40))
      (with-current-buffer buffer
        (window-text-pixel-size window nil nil nil nil nil)
        (homun-ui-smoke--header-text (if (listp header-line-format) header-line-format
                                       (list header-line-format)))))))

(defmacro homun-ui-smoke--with-transcript (&rest body)
  (declare (indent 0))
  `(let* ((dir (make-temp-file "smoke" t))
          (file (expand-file-name "session.jsonl" dir))
          (claude-transcript-projects-directory dir))
     (copy-file homun-ui-smoke--fixture file)
     (with-temp-buffer
       (claude-transcript-mode)
       (setq claude-transcript--file file)
       (unwind-protect (progn ,@body) (delete-directory dir t)))))

(ert-deftest homun-ui-smoke-transcript-narrow ()
  (homun-ui-smoke--with-transcript
    (claude-transcript--render claude-transcript-tail-turns)
    (should (stringp (homun-ui-smoke--narrow (current-buffer))))
    (should (> (buffer-size) 0))))

(ert-deftest homun-ui-smoke-board-narrow ()
  (cl-letf (((symbol-function 'claude-board--mains) #'ignore)
            ((symbol-function 'claude-board--handoffs) #'ignore)
            ((symbol-function 'claude-board--tasks) #'ignore)
            ((symbol-function 'claude-board--meters) #'ignore))
    (with-temp-buffer
      (claude-board-mode)
      (set-window-buffer (selected-window) (current-buffer))
      (unwind-protect
          (progn
            (claude-board--draw)
            (should (stringp (homun-ui-smoke--narrow (current-buffer))))
            (should (string-match-p "No agents" (buffer-string))))
        (when claude-board--resize-timer (cancel-timer claude-board--resize-timer))))))

(ert-deftest homun-ui-smoke-compose-narrow ()
  (with-temp-buffer
    (claude-compose-mode 1)
    (insert "a draft that is longer than forty columns so it has to wrap in a narrow frame")
    (should (stringp (homun-ui-smoke--narrow (current-buffer))))))

(defconst homun-ui-smoke-threshold 5.0
  "Seconds the large-fixture redraw may take: generous, it only catches a regression of order.")

(ert-deftest homun-ui-redraw-timing ()
  "Rendering 300 turns stays under `homun-ui-smoke-threshold'."
  (let* ((dir (make-temp-file "smoke" t))
         (file (expand-file-name "big.jsonl" dir))
         (claude-transcript-projects-directory dir)
         (lines (with-temp-buffer (insert-file-contents homun-ui-smoke--fixture)
                                  (split-string (buffer-string) "\n" t))))
    (with-temp-file file
      (dotimes (_ 25) (dolist (l lines) (insert l "\n"))))
    (unwind-protect
        (with-temp-buffer
          (claude-transcript-mode)
          (setq claude-transcript--file file)
          (let ((secs (car (benchmark-run 1 (claude-transcript--render 500)))))
            (message "homun-ui-redraw-timing: %.3f s for %d bytes" secs (buffer-size))
            (should (< secs homun-ui-smoke-threshold))))
      (delete-directory dir t))))

(provide 'homun-ui-smoke-test)
