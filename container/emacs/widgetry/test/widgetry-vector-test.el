;;; widgetry-vector-test.el --- Tests for widgetry-vector -*- lexical-binding: t; -*-

(require 'ert)
(require 'widgetry-vector)

(defmacro widgetry-vector-test--with (value seen &rest body)
  "Run BODY with a vector widget of VALUE, collecting notified values in SEEN."
  (declare (indent 2))
  `(with-temp-buffer
     (let* ((,seen nil)
            (widget (widget-create 'widgetry-vector :value ,value
                                   :notify (lambda (w &rest _) (push (widget-value w) ,seen)))))
       (widget-setup)
       (ignore ,seen)
       ,@body)))

(ert-deftest widgetry-vector-value-roundtrip ()
  (widgetry-vector-test--with [1.0 2.5 -0.5] seen
    (should (equal (widget-value widget) [1.0 2.5 -0.5]))))

(ert-deftest widgetry-vector-two-elements ()
  (widgetry-vector-test--with [1.0 2.0] seen
    (should (equal (widget-value widget) [1.0 2.0]))
    (should-not (string-match-p " Z " (buffer-string)))))

(ert-deftest widgetry-vector-notifies-once-with-whole-vector ()
  (widgetry-vector-test--with [1.0 2.0 3.0] seen
    (goto-char (point-min))
    (search-forward " Y ")
    (let ((last-command-event ?7))
      (widgetry-slider-input))
    (should (equal seen '([1.0 7.0 3.0])))))

(ert-deftest widgetry-vector-programmatic-set-is-silent ()
  (widgetry-vector-test--with [1.0 2.0 3.0] seen
    (widget-value-set widget [4.0 5.0 6.0])
    (should (equal (widget-value widget) [4.0 5.0 6.0]))
    (should-not seen)))

;; A vector's :step reaches its sliders.
(ert-deftest widgetry-vector-step-reaches-components ()
  (with-temp-buffer
    (let ((widget (widget-create 'widgetry-vector :value [0.0 0.0] :step 2)))
      (widget-setup)
      (should (equal (mapcar #'widgetry-slider--step (widget-get widget :children))
                     '(2 2))))))

;;; widgetry-vector-test.el ends here
