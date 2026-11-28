;;; widgetry-text-test.el --- Tests for widgetry-text -*- lexical-binding: t; -*-

(require 'ert)
(require 'widgetry-text)

(defmacro widgetry-text-test--with (args &rest body)
  "Run BODY with point on a text pill made with ARGS, as WIDGET."
  `(with-temp-buffer
     (let ((widget (widget-create 'widgetry-text ,@args)))
       (widget-setup)
       (goto-char (widget-get widget :from))
       (unwind-protect (progn ,@body)
         (cancel-function-timers #'widgetry-button--release)))))

(defun widgetry-text-test--type (text)
  "Replace the text being edited with TEXT, as typing would."
  (let ((overlay (plist-get widgetry-text--editing :overlay)))
    (goto-char (1+ (overlay-start overlay)))
    (delete-region (point) (1- (overlay-end overlay)))
    (insert text)))

(ert-deftest widgetry-text-edit-commits-in-place ()
  (let (told)
    (widgetry-text-test--with
     (:value "a" :notify (lambda (w &rest _) (push (widget-value w) told)))
     (setq buffer-read-only t)
     (set-buffer-modified-p nil)
     (widgetry-text-edit)
     (should-not buffer-read-only)
     (should-not (overlay-get (widget-get widget :widgetry-overlay) 'display))
     (widgetry-text-test--type "ab")
     (widgetry-text-commit)
     (should (equal (widget-value widget) "ab"))
     (should (equal told '("ab")))
     (should buffer-read-only)
     (should-not (buffer-modified-p))
     (should-not widgetry-text--editing)
     (should (string-match-p "ab" (overlay-get (widget-get widget :widgetry-overlay) 'display))))))

(ert-deftest widgetry-text-cancel-restores ()
  (widgetry-text-test--with
   (:value "a" :notify (lambda (&rest _) (error "notified")))
   (let ((before (buffer-string)))
     (widgetry-text-edit)
     (widgetry-text-test--type "zzz")
     (widgetry-text-cancel)
     (should (equal (widget-value widget) "a"))
     (should (equal (buffer-string) before)))))

(ert-deftest widgetry-text-leaving-cancels ()
  (widgetry-text-test--with
   (:value "a" :notify (lambda (&rest _) (error "notified")))
   (let ((inhibit-read-only t)) (insert "after"))
   (widgetry-text-edit)
   (widgetry-text-test--type "zz")
   (goto-char (point-max))
   (widgetry-text--check)
   (should-not widgetry-text--editing)
   (should (equal (widget-value widget) "a"))))

(ert-deftest widgetry-text-guards-the-rest-of-the-buffer ()
  (widgetry-text-test--with
   (:value "a")
   (let ((inhibit-read-only t)) (insert "after"))
   (widgetry-text-edit)
   (should-error (delete-region (point-max) (- (point-max) 2)) :type 'user-error)
   (widgetry-text-cancel)))

(ert-deftest widgetry-text-unchanged-is-silent ()
  (widgetry-text-test--with
   (:value "a" :notify (lambda (&rest _) (error "notified")))
   (widgetry-text-edit)
   (widgetry-text-commit)))

(ert-deftest widgetry-text-shows-placeholder-and-ellipsis ()
  (widgetry-text-test--with
   (:value "" :placeholder "branch" :width 8)
   (should (equal (widgetry-text--shown widget) " branch   ")))
  (widgetry-text-test--with
   (:value "0123456789" :width 6)
   (should (equal (widgetry-text--shown widget) " 01234… "))))

(ert-deftest widgetry-text-paste-appends-and-prepends-one-line ()
  (dolist (case '(("p" . "abX Y") ("P" . "X Yab")))
    (widgetry-text-test--with (:value "ab")
      (kill-new "X\nY")
      (funcall (intern (concat "widgetry-text-paste-" (car case))))
      (widgetry-text-commit)
      (should (equal (widget-value widget) (cdr case))))))

(provide 'widgetry-text-test)
;;; widgetry-text-test.el ends here

(define-derived-mode widgetry-text-test-mode special-mode "WT"
  "Read-only mode whose letters are undefined, like a transcript.")

(ert-deftest widgetry-text-types-in-readonly-mode ()
  (with-temp-buffer
    (widgetry-text-test-mode)
    (dolist (c (number-sequence ?a ?z))
      (define-key widgetry-text-test-mode-map (string c) #'undefined))
    (let ((inhibit-read-only t)
          (widget (widget-create 'widgetry-text :value "")))
      (widget-setup)
      (goto-char (widget-get widget :from))
      (set-window-buffer (selected-window) (current-buffer))
      (widgetry-text-edit)
      (execute-kbd-macro (kbd "a b c RET"))
      (should (equal (widget-value widget) "abc")))))

(ert-deftest widgetry-text-edit-survives-redraw ()
  (widgetry-text-test--with
   (:value "a")
   (widgetry-text-edit)
   (widgetry-redraw widget)
   (widgetry-text-cancel)
   (should-not (widget-get widget :editing))))

(require 'evil nil t)
(require 'magit-section nil t)

(when (and (featurep 'evil) (featurep 'magit-section))
  (define-derived-mode widgetry-text-test-evil-mode magit-section-mode "WTE"
    "Read-only transcript-like mode.")
  (evil-set-initial-state 'widgetry-text-test-evil-mode 'motion)
  (evil-define-key 'motion widgetry-text-test-evil-mode-map "a" #'ignore "d" #'ignore)

  (ert-deftest widgetry-text-types-under-evil-motion-state ()
    (evil-mode 1)
    (unwind-protect
        (with-temp-buffer
          (widgetry-text-test-evil-mode)
          (should (eq evil-state 'motion))
          (let ((inhibit-read-only t)
                (widget (widget-create 'widgetry-text :value "")))
            (widget-setup)
            (goto-char (widget-get widget :from))
            (set-window-buffer (selected-window) (current-buffer))
            (widgetry-text-edit)
            (execute-kbd-macro (kbd "a b c RET"))
            (should (equal (widget-value widget) "abc"))
            (should (eq evil-state 'motion))
            (should-not widgetry-text-editing-mode)))
      (evil-mode -1)))
  (defmacro widgetry-text-test--evil (value &rest body)
    `(progn
       (evil-mode 1)
       (unwind-protect
           (with-temp-buffer
             (widgetry-text-test-evil-mode)
             (let ((inhibit-read-only t)
                   (widget (widget-create 'widgetry-text :value ,value)))
               (widget-setup)
               (goto-char (widget-get widget :from))
               (set-window-buffer (selected-window) (current-buffer))
               ,@body))
         (evil-mode -1))))

  (ert-deftest widgetry-text-evil-insert-edits-and-escape-commits ()
    (widgetry-text-test--evil "x"
      (execute-kbd-macro (kbd "i a b c <escape>"))
      (should (equal (widget-value widget) "abcx"))
      (should (eq evil-state 'motion))
      (should-not widgetry-text-editing-mode)))

  (ert-deftest widgetry-text-evil-a-appends-and-C-g-cancels ()
    (widgetry-text-test--evil "x"
      (execute-kbd-macro (kbd "a y <escape>"))
      (should (equal (widget-value widget) "xy"))
      (execute-kbd-macro (kbd "a z C-g"))
      (should (equal (widget-value widget) "xy"))
      (should (eq evil-state 'motion)))))
