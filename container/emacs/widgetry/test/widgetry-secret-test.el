;;; widgetry-secret-test.el --- Tests for widgetry-secret -*- lexical-binding: t; -*-

(require 'ert)
(require 'widgetry-secret)

(defmacro widgetry-secret-test--with (accept &rest body)
  "Run BODY with point on a secret pill whose :accept is ACCEPT, as WIDGET."
  `(with-temp-buffer
     (let ((widget (widget-create 'widgetry-secret :value " Token " :accept ,accept)))
       (widget-setup)
       (goto-char (widget-get widget :from))
       (unwind-protect (progn ,@body)
         (cancel-function-timers #'widgetry-button--release)))))

(ert-deftest widgetry-secret-hands-over-and-wipes ()
  (let (kept seen)
    (widgetry-secret-test--with
     (lambda (secret _w) (setq seen secret kept (copy-sequence secret)) t)
     (cl-letf (((symbol-function 'read-passwd) (lambda (&rest _) (copy-sequence "s3cret"))))
       (widgetry-secret--ask widget))
     (should (equal kept "s3cret"))
     ;; Wiped after accept returned: the string accept saw is all NULs now
     (should (equal seen (make-string 6 0)))
     (should (widget-get widget :disabled))
     (should (equal (widget-get widget :tag) " ✓ ")))))

(ert-deftest widgetry-secret-refused-stays-open ()
  (widgetry-secret-test--with
   (lambda (&rest _) nil)
   (cl-letf (((symbol-function 'read-passwd) (lambda (&rest _) (copy-sequence "x"))))
     (widgetry-secret--ask widget))
   (should-not (widget-get widget :disabled))
   (should (equal (widget-get widget :tag) " 🔒 "))))

(ert-deftest widgetry-secret-empty-is-ignored ()
  (widgetry-secret-test--with
   (lambda (&rest _) (error "accepted"))
   (cl-letf (((symbol-function 'read-passwd) (lambda (&rest _) (copy-sequence ""))))
     (widgetry-secret--ask widget))))

(ert-deftest widgetry-secret-leaves-kill-ring-alone ()
  (let ((kill-ring (list "old")))
    (widgetry-secret-test--with
     (lambda (&rest _) t)
     (cl-letf (((symbol-function 'read-passwd)
                (lambda (&rest _) (kill-new "leak") (copy-sequence "x"))))
       (widgetry-secret--ask widget)))
    (should (equal kill-ring '("old")))))

(defmacro widgetry-secret-test--clipboard (text &rest body)
  "Run BODY with the clipboard TEXT; clipboard writes go to `cleared'."
  `(let (cleared)
     (cl-letf (((symbol-function 'gui-get-selection) (lambda (&rest _) (and ,text (copy-sequence ,text))))
               ((symbol-function 'gui-set-selection) (lambda (_s v) (setq cleared (list v))))
               ((symbol-function 'y-or-n-p) (lambda (p) (setq widgetry-secret-test--asked p) t)))
       ,@body)))

(defvar widgetry-secret-test--asked nil)

(ert-deftest widgetry-secret-paste-saves-and-clears ()
  (let (seen)
    (widgetry-secret-test--with
     (lambda (secret _w) (setq seen (copy-sequence secret)) t)
     (widget-put widget :name "tok")
     (let ((kill-ring '("keep")))
       (widgetry-secret-test--clipboard
        "s3cret"
        (widgetry-secret-paste)
        (should (equal kill-ring '("keep")))
        (should (equal seen "s3cret"))
        ;; The question has the length and name, never the text
        (should (equal widgetry-secret-test--asked
                       "Save 6 characters from the clipboard as tok? "))
        (should (equal cleared '("")))
        (should (widget-get widget :disabled)))))))

(ert-deftest widgetry-secret-paste-declined-keeps-clipboard ()
  (widgetry-secret-test--with
   (lambda (&rest _) (error "accepted"))
   (widgetry-secret-test--clipboard
    "x"
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
      (widgetry-secret-paste))
    (should-not cleared)
    (should-not (widget-get widget :disabled)))))

(ert-deftest widgetry-secret-paste-keeps-clipboard-when-asked-to ()
  (let ((widgetry-secret-clear-clipboard nil))
    (widgetry-secret-test--with
     (lambda (&rest _) t)
     (widgetry-secret-test--clipboard "x" (widgetry-secret-paste) (should-not cleared)))))

(ert-deftest widgetry-secret-has-paste-segment ()
  (widgetry-secret-test--with
   (lambda (&rest _) t)
   (should (string-suffix-p " Paste " (widgetry-shown widget)))))

(provide 'widgetry-secret-test)
(ert-deftest widgetry-secret-clipboard-reads-the-same-text-twice ()
  "A paste function of the session's own is asked every time, so the same
clipboard pastes again; `gui-selection-value' alone would answer nil."
  (let ((interprogram-paste-function (lambda () "tok-123")))
    (cl-letf (((symbol-function 'gui-get-selection) (lambda (&rest _) nil))
              ((symbol-function 'gui-selection-value) (lambda () nil)))
      (should (equal (widgetry-secret--clipboard) "tok-123"))
      (should (equal (widgetry-secret--clipboard) "tok-123")))))

(ert-deftest widgetry-secret-clear-clipboard-uses-the-cut-function ()
  (let* ((cut nil)
         (interprogram-cut-function (lambda (text) (setq cut text))))
    (cl-letf (((symbol-function 'gui-set-selection) #'ignore))
      (widgetry-secret--clear-clipboard)
      (should (equal cut "")))))

;;; widgetry-secret-test.el ends here
