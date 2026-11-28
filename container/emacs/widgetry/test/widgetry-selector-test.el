;;; widgetry-selector-test.el --- Tests for widgetry-selector -*- lexical-binding: t; -*-

(require 'ert)
(require 'widgetry-selector)

(defmacro widgetry-selector-test--with (value seen &rest body)
  "Run BODY with point on a selector of VALUE, collecting notified values in SEEN."
  (declare (indent 2))
  `(with-temp-buffer
     (let* ((,seen nil)
            (widget (widget-create 'widgetry-selector :value ,value
                                   :choices '("Off" "Hard" "Soft" "Contact")
                                   :notify (lambda (w &rest _) (push (widget-value w) ,seen)))))
       (widget-setup)
       (goto-char (widget-get widget :from))
       (ignore ,seen)
       ,@body)))

(ert-deftest widgetry-selector-next-previous-wrap ()
  (widgetry-selector-test--with "Contact" seen
    (widgetry-selector-next)
    (should (equal (widget-value widget) "Off"))
    (widgetry-selector-previous)
    (should (equal (widget-value widget) "Contact"))
    (should (equal seen '("Contact" "Off")))))

(ert-deftest widgetry-selector-programmatic-set-is-silent ()
  (widgetry-selector-test--with "Off" seen
    (widget-value-set widget "Soft")
    (should-not seen)))

(ert-deftest widgetry-selector-fixed-width ()
  (widgetry-selector-test--with "Off" seen
    (let ((width (string-width (widgetry-shown widget))))
      (dolist (choice '("Hard" "Contact" "Soft"))
        (widget-value-set widget choice)
        (should (= width (string-width (widgetry-shown widget))))))))

(ert-deftest widgetry-selector-choice-by-steps ()
  (widgetry-selector-test--with "Off" seen
    (should (equal (widgetry-selector--choice widget "Off" 2) "Soft"))
    (should (equal (widgetry-selector--choice widget "Off" -1) "Contact"))
    (should (equal (widgetry-selector--choice widget "Hard" 7) "Off"))))

(ert-deftest widgetry-steps-threshold ()
  (should (= (widgetry-steps 11 12) 0))
  (should (= (widgetry-steps 12 12) 1))
  (should (= (widgetry-steps 30 12) 2))
  (should (= (widgetry-steps -13 12) -1))
  (should (= (widgetry-steps -35 12) -2))
  (let ((widgetry-drag-threshold 5))
    (should (= (widgetry-steps 11) 2))))

(ert-deftest widgetry-selector-progress ()
  (should (= (widgetry-selector--progress 0 30) 0.0))
  (should (= (widgetry-selector--progress 15 30) 0.5))
  (should (= (widgetry-selector--progress 45 30) 0.5))
  (should (= (widgetry-selector--progress -15 30) 0.5))
  (should (= (widgetry-selector--progress -30 30) 0.0)))

(ert-deftest widgetry-selector-shades-alternate ()
  (should (eq (widgetry-selector--shade 0) 'widgetry-selector-value))
  (should (eq (widgetry-selector--shade 1) 'widgetry-selector-value-alt))
  (should (eq (widgetry-selector--shade 2) 'widgetry-selector-value)))

(ert-deftest widgetry-selector-fill-colours-label-chars ()
  (with-temp-buffer
    (let ((widget (widget-create 'widgetry-selector :value "Hard"
                                 :choices '("Off" "Hard" "Soft"))))
      (widget-setup)
      (let ((width (string-width (widgetry-shown widget)))
            (text (widgetry-selector--text widget)))
        (widget-put widget :fill 0.5)
        (widget-value-set widget "Hard")
        (should (string-match-p "Hard" (widgetry-shown widget)))
        (let ((shown (widgetry-shown widget))
              (k (widgetry-fill-split 0.5 (length text))))
          (should (eq (get-text-property (+ 3 (1- k)) 'face shown)
                      'widgetry-selector-value))
          (should (eq (get-text-property (+ 3 k) 'face shown)
                      'widgetry-selector-value-alt)))
        (widget-put widget :fill nil)
        (widget-value-set widget "Hard")
        (should (= width (string-width (widgetry-shown widget))))))))

;;; widgetry-selector-test.el ends here
