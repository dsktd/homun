;;; widgetry-link-test.el --- Tests for widgetry-link -*- lexical-binding: t; -*-

(require 'ert)
(require 'widgetry-link)

(defmacro widgetry-link-test--with (&rest body)
  "Run BODY with point on a link to a test URL, as WIDGET."
  `(with-temp-buffer
     (let ((widget (widget-create 'widgetry-link :value " Docs " :url "https://example.org/x")))
       (widget-setup)
       (goto-char (widget-get widget :from))
       (unwind-protect (progn ,@body)
         (cancel-function-timers #'widgetry-button--release)))))

(ert-deftest widgetry-link-press-browses-once ()
  (widgetry-link-test--with
   (let (opened)
     (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (push url opened))))
       (widgetry-button-press))
     (should (equal opened '("https://example.org/x"))))))

(ert-deftest widgetry-link-draws-arrow-and-title ()
  (widgetry-link-test--with
   (let ((shown (overlay-get (widget-get widget :widgetry-overlay) 'display)))
     (should (string-match-p "↗" shown))
     (should (string-match-p "Docs" shown)))))

(ert-deftest widgetry-link-help-echo-is-the-url ()
  (widgetry-link-test--with
   (let ((echo (overlay-get (widget-get widget :widgetry-overlay) 'help-echo)))
     (should (equal (funcall echo) "https://example.org/x")))))

(ert-deftest widgetry-link-no-url-does-nothing ()
  (with-temp-buffer
    (let ((widget (widget-create 'widgetry-link)))
      (widget-setup)
      (cl-letf (((symbol-function 'browse-url) (lambda (&rest _) (error "opened"))))
        (widgetry-link--open widget)))))

(provide 'widgetry-link-test)
;;; widgetry-link-test.el ends here
