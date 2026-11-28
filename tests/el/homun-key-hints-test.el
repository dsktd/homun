;;; homun-key-hints-test.el --- ERT: no key hint in header or mode lines by default -*- lexical-binding: t -*-
;; emacs --batch -L container/emacs -l tests/el/homun-key-hints-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'dbus)
(defvar claude-service-dir (make-temp-file "svc" t))
(dolist (lib '(claude claude-transcript claude-compose claude-board claude-doctor claude-follow homun-stage-store))
  (require lib nil t))

(defconst homun-key-hints-test--key
  (rx (or (seq (any "CM") "-" (any "a-zA-Z0-9") (or " " eol))
          (seq symbol-start (or "RET" "TAB" "SPC") symbol-end)
          (seq bol (or "q" "gr" "g") " " (any "a-z"))
          (seq " " (or "q" "gr") " " (any "a-z"))
          "? help")))

;; `format-mode-line' returns "" in batch, so walk the spec: strings, (:eval FORM), lists, variables.
(defun homun-key-hints-test--text (spec)
  (cond ((stringp spec) spec)
        ((eq (car-safe spec) :eval) (homun-key-hints-test--text (eval (cadr spec) t)))
        ((consp spec) (mapconcat #'homun-key-hints-test--text (if (listp (cdr spec)) spec (list (car spec))) ""))
        ((and spec (symbolp spec) (boundp spec)) (homun-key-hints-test--text (symbol-value spec)))
        (t "")))

(defun homun-key-hints-test--lines ()
  "The header line and the mode-line hint items of the current buffer, as text."
  (concat (homun-key-hints-test--text header-line-format) "\n"
          (homun-key-hints-test--text mode-line-misc-info)))

(defun homun-key-hints-test--check (mode)
  (with-temp-buffer
    (funcall mode)
    (let ((text (homun-key-hints-test--lines)))
      (should-not (string-match-p homun-key-hints-test--key text)))))

(ert-deftest homun-key-hint-off-by-default ()
  (should (null homun-key-hints))
  (should (equal (homun-key-hint "q quit") "")))

(ert-deftest homun-key-hint-on-shows-text ()
  (let ((homun-key-hints t))
    (should (equal (homun-key-hint "q quit") "q quit"))))

(ert-deftest homun-key-hints-claude-header-default ()
  (with-temp-buffer
    (set-window-buffer (selected-window) (current-buffer))
    (setq mode-line-format nil
          header-line-format (claude-header "T" "RET open | gr refresh | q quit"))
    (should-not (string-match-p homun-key-hints-test--key (homun-key-hints-test--lines)))
    (let ((homun-key-hints t))
      (should (string-match-p "RET open" (homun-key-hints-test--lines))))))

(dolist (mode '(claude-transcript-mode claude-compose-mode claude-board-mode
                claude-follow-mode homun-stage-mode))
  (when (fboundp mode)
    (eval `(ert-deftest ,(intern (format "homun-key-hints-%s-default" mode)) ()
             (homun-key-hints-test--check ',mode))
          t)))

(ert-deftest homun-key-hints-board-header-default ()
  (when (fboundp 'claude-board--header)
    (with-temp-buffer
      (set-window-buffer (selected-window) (current-buffer))
      (setq mode-line-format nil header-line-format (claude-board--header))
      (should-not (string-match-p homun-key-hints-test--key (homun-key-hints-test--lines)))
      (let ((homun-key-hints t))
        (should (string-match-p "gr redraw" (homun-key-hints-test--lines)))))))

(ert-deftest homun-key-hints-refresh-open-buffer ()
  "An open view holding a stale literal header gets the live one on refresh."
  (with-temp-buffer
    (claude-board-mode)
    (setq header-line-format '(" Agent board · RET open · x stop · ? help"))
    (homun-key-hints-refresh)
    (should-not (string-match-p homun-key-hints-test--key (homun-key-hints-test--lines)))))

(ert-deftest homun-key-hints-set-option-refreshes ()
  (let ((updated nil))
    (cl-letf (((symbol-function 'force-mode-line-update) (lambda (&rest _) (setq updated t))))
      (customize-set-variable 'homun-key-hints nil))
    (should updated)))
