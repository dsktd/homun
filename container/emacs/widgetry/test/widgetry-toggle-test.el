;;; widgetry-toggle-test.el --- Tests for widgetry-toggle -*- lexical-binding: t; -*-

(require 'ert)
(require 'widgetry-toggle)

(defmacro widgetry-toggle-test--with (value seen &rest body)
  "Run BODY with point on a toggle of VALUE, collecting notified values in SEEN."
  (declare (indent 2))
  `(with-temp-buffer
     (let* ((,seen nil)
            (widget (widget-create 'widgetry-toggle :value ,value
                                   :notify (lambda (w &rest _) (push (widget-value w) ,seen)))))
       (widget-setup)
       (goto-char (widget-get widget :from))
       (ignore ,seen)
       ,@body)))

(ert-deftest widgetry-toggle-flip ()
  (widgetry-toggle-test--with nil seen
    (widgetry-toggle-flip)
    (should (eq (widget-value widget) t))
    (widgetry-toggle-flip)
    (should (eq (widget-value widget) nil))
    (should (equal seen '(nil t)))))

(ert-deftest widgetry-toggle-programmatic-set-is-silent ()
  (widgetry-toggle-test--with nil seen
    (widget-value-set widget t)
    (should-not seen)))

(ert-deftest widgetry-toggle-on-is-green ()
  (widgetry-toggle-test--with t seen
    (should (string-match-p "ON" (widgetry-shown widget)))
    (should (eq (get-text-property 4 'face (widgetry-shown widget)) 'widgetry-value-on))))

(ert-deftest widgetry-toggle-keymap-on-text ()
  (widgetry-toggle-test--with t seen
    (should (eq (get-char-property (point) 'keymap) widgetry-toggle-map))
    (should (eq (get-char-property (+ (point) 4) 'keymap) widgetry-toggle-map))))

(ert-deftest widgetry-toggle-fixed-width ()
  (widgetry-toggle-test--with nil seen
    (let ((off (string-width (widgetry-shown widget))))
      (widget-value-set widget t)
      (should (= off (string-width (widgetry-shown widget)))))))

(ert-deftest widgetry-toggle-tag-face-state ()
  (should (eq (widgetry-toggle--tag-face t 'x) 'widgetry-toggle-on-tag))
  (should (eq (widgetry-toggle--tag-face nil 'x) 'x)))

(ert-deftest widgetry-toggle-on-colours-the-tag ()
  (widgetry-toggle-test--with t seen
    (should (eq (get-text-property 0 'face (widgetry-shown widget)) 'widgetry-toggle-on-tag))
    (widget-value-set widget nil)
    (should (eq (get-text-property 0 'face (widgetry-shown widget))
                'widgetry-toggle-tag))))

;;; widgetry-toggle-test.el ends here
