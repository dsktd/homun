;;; widgetry-slider-test.el --- Tests for widgetry-slider -*- lexical-binding: t; -*-

(require 'ert)
(require 'widgetry-slider)

(defmacro widgetry-slider-test--with (value &rest body)
  "Run BODY with point on a fresh slider of VALUE, bound to `widget'."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((widget (widget-create 'widgetry-slider-x :value ,value)))
       (widget-setup)
       (goto-char (widget-get widget :from))
       ,@body)))

(defun widgetry-slider-test--type (&rest chars)
  "Type CHARS into the slider at point."
  (dolist (char chars)
    (let ((last-command-event char))
      (widgetry-slider-input))))

(ert-deftest widgetry-slider-typing-replaces-value ()
  (widgetry-slider-test--with 1.0
    (widgetry-slider-test--type ?2 ?. ?5)
    (widgetry-slider-submit)
    (should (= (widget-value widget) 2.5))
    (should-not (widget-get widget :initial))))

(ert-deftest widgetry-slider-second-point-ignored ()
  (widgetry-slider-test--with 0.0
    (widgetry-slider-test--type ?1 ?. ?. ?2)
    (should (= (widget-value widget) 1.2))))

(ert-deftest widgetry-slider-cancel-restores ()
  (widgetry-slider-test--with 3.0
    (widgetry-slider-test--type ?9)
    (widgetry-slider-cancel)
    (should (= (widget-value widget) 3.0))))

(ert-deftest widgetry-slider-delete-backs-up ()
  (widgetry-slider-test--with 0.0
    (widgetry-slider-test--type ?4 ?2)
    (widgetry-slider-delete)
    (should (= (widget-value widget) 4))))

(ert-deftest widgetry-slider-notifies-user-changes ()
  (with-temp-buffer
    (let* ((seen nil)
           (widget (widget-create 'widgetry-slider :value 1.0
                                  :notify (lambda (w &rest _) (push (widget-value w) seen)))))
      (widget-setup)
      (widget-value-set widget 2.0)       ; programmatic: no notify
      (goto-char (widget-get widget :from))
      (widgetry-slider-test--type ?7)
      (should (equal seen '(7.0))))))

(ert-deftest widgetry-slider-faces-survive-font-lock ()
  (widgetry-slider-test--with 1.0
    (should (eq (get-text-property 0 'face (widgetry-shown widget)) 'widgetry-slider-x))))

(ert-deftest widgetry-distance ()
  (should (= (widgetry-distance '(0 . 0) '(10 . -5)) 15)))

(ert-deftest widgetry-slider-drag-value-is-rounded ()
  (should (= (widgetry-round (+ 0 (* 0.01 136)) 2) 1.36))
  (should (equal (number-to-string (widgetry-round (* 0.01 136) 2)) "1.36"))
  (widgetry-slider-test--with 0.0
    (should (= (widgetry-slider--decimals widget) 2))))

(ert-deftest widgetry-slider-display-fixed-decimals ()
  (widgetry-slider-test--with 1.0
    (let ((width (string-width (widgetry-shown widget))))
      (widget-value-set widget 1.36)
      (should (string-match-p " 1\\.36 " (widgetry-shown widget)))
      (widget-value-set widget 2.5)
      (should (string-match-p " 2\\.50 " (widgetry-shown widget)))
      (should (= width (string-width (widgetry-shown widget)))))))

(ert-deftest widgetry-slider-typed-value-limited-to-decimals ()
  (widgetry-slider-test--with 0.0
    (widgetry-slider-test--type ?1 ?. ?2 ?3 ?4)
    (widgetry-slider-submit)
    (should (= (widget-value widget) 1.23))))

(ert-deftest widgetry-slider-parts ()
  (should (equal (widgetry-slider--sign-magnitude -1.5 2 5) '("−" . " 1.50")))
  (should (equal (widgetry-slider--sign-magnitude 0.0 2 5) '(" " . " 0.00")))
  (should (equal (widgetry-slider--sign-magnitude -0.001 2 5) '(" " . " 0.00")))
  (should (equal (widgetry-slider--sign-magnitude 12.25 2 5) '("+" . "12.25")))
  (should (equal (widgetry-slider--sign-magnitude 0.001 2 5) '(" " . " 0.00"))))

(ert-deftest widgetry-slider-width-constant-through-zero ()
  (widgetry-slider-test--with 12.25
    (let ((width (string-width (widgetry-shown widget))))
      (dolist (v '(-1.5 0.0 12.25 -99.99))
        (widget-value-set widget v)
        (should (= width (string-width (widgetry-shown widget)))))
      (widget-value-set widget -1.5)
      (let ((shown (widgetry-shown widget)))
        (should (equal (substring shown 3 4) "−"))
        (should (eq (get-text-property 3 'face shown) 'widgetry-sign))
        (should (eq (get-char-property (widget-get widget :from) 'keymap)
                    widgetry-slider-map))))))

(ert-deftest widgetry-slider-width-from-min-max ()
  (with-temp-buffer
    (let ((widget (widget-create 'widgetry-slider :value 1.0 :min -10.0 :max 100.0)))
      (should (= (widgetry-slider--width widget) 6)))
    (let ((widget (widget-create 'widgetry-slider :value 1.0 :min -1.0 :max 5.0)))
      (should (= (widgetry-slider--width widget) 4)))))

;; :step overrides the global drag step.
(ert-deftest widgetry-slider-step-default-is-global ()
  (widgetry-slider-test--with 0.0
    (should (= (widgetry-slider--step widget) widgetry-slider-drag-step))))

(ert-deftest widgetry-slider-step-per-widget ()
  (with-temp-buffer
    (let ((widget (widget-create 'widgetry-slider :value 0 :step 5 :min 0 :max 1000)))
      (widget-setup)
      (goto-char (widget-get widget :from))
      (should (= (widgetry-slider--step widget) 5))
      (should (= (widgetry-slider--decimals widget) 0))
      (cl-letf (((symbol-function 'widgetry-drag)
                 (lambda (f) (funcall f 10) t)))
        (widgetry-slider-drag nil))
      (should (= (widget-value widget) 50)))))

;;; widgetry-slider-test.el ends here
