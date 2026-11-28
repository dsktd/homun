;;; widgetry-meter-test.el --- Tests for widgetry-meter -*- lexical-binding: t; -*-

(require 'ert)
(require 'widgetry-meter)

(defmacro widgetry-meter-test--with (args seen &rest body)
  "Run BODY with point on a meter made with ARGS, notified values in SEEN."
  (declare (indent 2))
  `(with-temp-buffer
     (let* ((,seen nil)
            (widget (apply #'widget-create 'widgetry-meter
                           :notify (lambda (w &rest _) (push (widget-value w) ,seen))
                           ,args)))
       (widget-setup)
       (goto-char (widget-get widget :from))
       (ignore ,seen)
       ,@body)))

(ert-deftest widgetry-meter-fraction ()
  (should (= (widgetry-meter--fraction 5 0 10) 0.5))
  (should (= (widgetry-meter--fraction 20 0 10) 1.0))
  (should (= (widgetry-meter--fraction -3 0 10) 0.0))
  (should (= (widgetry-meter--fraction 1 2 2) 0.0)))

(ert-deftest widgetry-meter-svg-fill-to-the-pixel ()
  (let* ((metrics '(8 16 "monospace" 13 12))
         (paint '("#2F2F2F" "#CBCBCB" "normal"))
         (svg (image-property
               (widgetry--svg-draw metrics `((" ▅ " ,paint 0.0 nil)
                                             ("  25% " ,paint 0.25 ("#2568EA" "#FFF" "normal"))))
               :data)))
    (should (string-match-p "width=\"72\" height=\"16\"" svg))
    ;; A quarter of 48 pixels
    (should (string-match-p "width=\"12\"[^>]*fill=\"#2568EA\"" svg))))

(ert-deftest widgetry-meter-percentage-fixed-width ()
  (widgetry-meter-test--with '(:value 0.0) seen
    (let ((width (string-width (widgetry-shown widget))))
      (widget-value-set widget 1.0)
      (should (= width (string-width (widgetry-shown widget))))
      (should (string-match-p "100%" (widgetry-shown widget))))))

(ert-deftest widgetry-meter-clamps-and-types-like-a-slider ()
  (widgetry-meter-test--with '(:value 0.5 :min 0 :max 10) seen
    (widget-value-set widget 50)
    (should (= (widget-value widget) 10))
    (let ((last-command-event ?3))
      (widgetry-slider-input))
    (should (equal seen '(3.0)))))

(ert-deftest widgetry-meter-keymap-and-faces ()
  (widgetry-meter-test--with '(:value 0.5) seen
    (should (eq (get-char-property (point) 'keymap) widgetry-meter-map))
    (should (eq (get-text-property 3 'face (widgetry-shown widget)) 'widgetry-meter-fill))))

(ert-deftest widgetry-meter-tty-fill-ends-in-an-eighth ()
  ;; Batch Emacs is a terminal frame: 3/8 of a cell past 2 whole ones
  (should-not (display-graphic-p))
  (let ((bar (widgetry-cells `(("      24% " widgetry-slider-value ,(/ 2.375 10) widgetry-meter-fill)))))
    (should (= 10 (length bar)))
    (should (eq 'widgetry-meter-fill (get-text-property 1 'face bar)))
    (should (equal "▍" (substring bar 2 3)))
    (should (equal " " (substring bar 3 4)))))

(ert-deftest widgetry-meter-tty-full-and-empty ()
  (let ((full (widgetry-cells '(("   100% " widgetry-slider-value 1.0 widgetry-meter-fill))))
        (empty (widgetry-cells '(("     0% " widgetry-slider-value 0.0 widgetry-meter-fill)))))
    (dotimes (i 8)
      (should (eq 'widgetry-meter-fill (get-text-property i 'face full)))
      (should (eq 'widgetry-slider-value (get-text-property i 'face empty))))
    (should-not (string-match-p "[▏▎▍▌▋▊▉]" (concat full empty)))))

(ert-deftest widgetry-meter-tty-drag-spans-the-bar ()
  ;; A drag over the whole bar is the whole range, counted in cells
  (let ((widgetry-tty-cell-pixels 10))
    (should (= 10 (widgetry-cell-scale)))
    (widgetry-meter-test--with '(:value 0.0 :width 12) seen
      (should (= (* 12 (widgetry-cell-scale))
                 (* (widgetry-cell-scale) (widgetry-meter--pixels widget)))))))

;;; widgetry-meter-test.el ends here
(ert-deftest widgetry-meter-read-only ()
  (widgetry-meter-test--with '(:value 0.5 :read-only t :fill-face widgetry-meter-fill-warn) seen
    (should-not (get-char-property (point) 'keymap))
    (should (eq 'widgetry-meter-fill-warn (get-text-property 3 'face (widgetry-shown widget))))
    (widget-put widget :initial 0.5)
    (widget-value-set widget 0.9)
    (should-not seen)
    (should (string-match-p "90%" (widgetry-shown widget)))))

