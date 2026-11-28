;;; widgetry-button-test.el --- Tests for widgetry-button -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'widgetry-button)

(defun widgetry-button-test--shown (widget)
  "The string WIDGET's overlay shows (batch Emacs is a terminal frame)."
  (overlay-get (widget-get widget :widgetry-overlay) 'display))

(defun widgetry-button-test--face (widget i)
  "The face of the I-th character WIDGET shows."
  (get-text-property i 'face (widgetry-button-test--shown widget)))

(defmacro widgetry-button-test--with (args count &rest body)
  "Run BODY with point on a button made with ARGS, counting notifies in COUNT."
  (declare (indent 2))
  `(with-temp-buffer
     (let* ((,count 0)
            (widget (apply #'widget-create 'widgetry-button
                           :notify (lambda (&rest _) (cl-incf ,count))
                           ,args)))
       (widget-setup)
       (goto-char (widget-get widget :from))
       (unwind-protect (progn ,@body)
         (cancel-function-timers #'widgetry-button--release)
         (widgetry-button--hint-end widget)))))

(ert-deftest widgetry-button-press-notifies-once ()
  (widgetry-button-test--with '(:value " Run ") count
    (widgetry-button-press)
    (should (= count 1))))

(ert-deftest widgetry-button-looks-pressed-then-normal ()
  (widgetry-button-test--with '(:tag " ● " :value " Run ") count
    (widgetry-button-press)
    (should (eq (widgetry-button-test--face widget 4) 'widgetry-button-pressed))
    (should (eq (widgetry-button-test--face widget 0) 'widgetry-button-pressed-tag))
    (widgetry-button--release widget)
    (should (eq (widgetry-button-test--face widget 4)
                'widgetry-button-value))))

(ert-deftest widgetry-button-disabled-ignores ()
  (widgetry-button-test--with '(:value " Run " :disabled t) count
    (widgetry-button-press)
    (should (= count 0))
    (should (eq (widgetry-button-test--face widget 0) 'widgetry-button-disabled))))

(ert-deftest widgetry-button-fill-fraction ()
  (should (= (widgetry-button--fill 0 80 0) 0.0))
  (should (= (widgetry-button--fill 40 80 0) 0.5))
  (should (= (widgetry-button--fill 200 80 0) 1.0))
  (should (= (widgetry-button--fill -20 80 0) 0.0))
  ;; Full one lead before the confirm point, so it shows before arming
  (should (= (widgetry-button--fill 72 80 8) 1.0))
  (should-not (widgetry-button--confirmed-p 72 80)))

(ert-deftest widgetry-button-confirm-decision ()
  (let ((widgetry-button-confirm-distance nil))
    (should (widgetry-button--confirmed-p 80 80))
    (should-not (widgetry-button--confirmed-p 79 80)))
  (let ((widgetry-button-confirm-distance 30))
    (should (widgetry-button--confirmed-p 30 80))))

(ert-deftest widgetry-button-confirm-click-shows-hint-only ()
  (widgetry-button-test--with '(:tag " ● " :value " Delete " :confirm t) count
    (widgetry-button-press)
    (should (= count 0))
    (should (string-match-p "← drag" (widgetry-button-test--shown widget)))
    (widgetry-button--hint-end widget)
    (should-not (string-match-p "drag" (widgetry-button-test--shown widget)))
    (should (= count 0))))

(ert-deftest widgetry-button-confirm-double-press-confirms ()
  (widgetry-button-test--with '(:tag " ● " :value " Delete " :confirm t) count
    (widgetry-button-press)
    (widgetry-button-press)
    (should (= count 1))
    (should-not (string-match-p "drag" (widgetry-button-test--shown widget)))))

(ert-deftest widgetry-button-fill-colours-label-chars ()
  (widgetry-button-test--with '(:tag " ● " :value " Delete " :confirm t) count
    (widget-put widget :fill 0.5)
    (widgetry-button--redraw widget)
    (should (string-match-p "Delete" (buffer-string)))
    (should (eq (widgetry-button-test--face widget (+ 3 3)) 'widgetry-button-fill))
    (should (eq (widgetry-button-test--face widget (+ 3 5)) 'widgetry-button-value))
    (should (eq (get-char-property (point) 'keymap) widgetry-button-map))))

(ert-deftest widgetry-button-tag-face-state ()
  (should (eq (widgetry-button--tag-face nil nil 'x) 'x))
  (should (eq (widgetry-button--tag-face nil t 'x) 'widgetry-button-armed-tag))
  (should (eq (widgetry-button--tag-face nil nil 'x t) 'widgetry-button-pressed-tag))
  (should (eq (widgetry-button--tag-face t t 'x) 'widgetry-button-disabled)))

(ert-deftest widgetry-button-armed-tag-drawn ()
  (widgetry-button-test--with '(:tag " ● " :value " Delete " :confirm t) count
    (widget-put widget :ready t)
    (widgetry-button--redraw widget)
    (should (eq (widgetry-button-test--face widget 0)
                'widgetry-button-armed-tag))
    (widget-put widget :ready nil)
    (widgetry-button--redraw widget)
    (should (eq (widgetry-button-test--face widget 0)
                'widgetry-button-tag))))

(ert-deftest widgetry-button-ready-keeps-label ()
  (widgetry-button-test--with '(:tag " ● " :value " Delete " :confirm t) count
    (widget-put widget :fill 1.0)
    (widget-put widget :ready t)
    (widgetry-button--redraw widget)
    (should (string-match-p "Delete" (buffer-string)))
    (should-not (string-match-p "Release" (buffer-string)))
    (widget-put widget :ready nil)
    (widget-put widget :fill 0.0)
    (widgetry-button--redraw widget)
    (should (string-match-p "Delete" (buffer-string)))))

(ert-deftest widgetry-button-drag-off-cancels ()
  (widgetry-button-test--with '(:value " Run ") count
    (should (widgetry-button--hit-p (+ (point) 2) widget))
    (should-not (widgetry-button--hit-p (1- (point)) widget))
    (should-not (widgetry-button--hit-p (+ (widget-get widget :to) 5) widget))
    (should-not (widgetry-button--hit-p nil widget))))

(ert-deftest widgetry-button-keymap-and-fixed-width ()
  (widgetry-button-test--with '(:value " Run " :confirm t) count
    (should (eq (get-char-property (point) 'keymap) widgetry-button-map))
    (let ((text (buffer-string))
          (width (string-width (widgetry-button-test--shown widget))))
      (widgetry-button-press)
      (widget-put widget :fill 0.4)
      (widgetry-button--redraw widget)
      (should (= width (string-width (widgetry-button-test--shown widget))))
      (widgetry-button-press)
      ;; The buffer text never changes, only the overlay's display
      (should (equal-including-properties text (buffer-string))))))

(ert-deftest widgetry-button-keeps-line-prefix ()
  (with-temp-buffer
    (insert (propertize "x" 'line-prefix "| "))
    (let ((widget (widget-create 'widgetry-button :value " Run ")))
      (put-text-property (point-min) (point-max) 'line-prefix "| ")
      (widget-put widget :pressed t)
      (widgetry-button--redraw widget)
      (should (equal (get-text-property (1- (point-max)) 'line-prefix) "| ")))))

(ert-deftest widgetry-button-svg-same-size ()
  (let* ((metrics '(8 16 "monospace" 13 12))
         (paint '("#2F2F2F" "#CBCBCB" "normal"))
         (fill '("#CD4542" "#FFFFFF" "bold"))
         (size (lambda (f) (image-property (widgetry--svg-draw
                                             metrics `((" ● " ,paint 0.0 nil)
                                                       (" Run " ,paint ,f ,fill)))
                                            :data))))
    (dolist (f '(0.0 0.37 1.0))
      (should (string-match-p "width=\"64\" height=\"16\"" (funcall size f))))))

(ert-deftest widgetry-button-shows-only-its-tag ()
  (dolist (confirm '(nil t hold))
    (widgetry-button-test--with (list :value " Go " :tag " ✓ " :style 'motion :confirm confirm)
        _count
      (should (equal " ✓  Go " (substring-no-properties (widgetry-button-test--shown widget)))))
    (widgetry-button-test--with (list :value " Go " :style 'motion :confirm confirm)
        _count
      (should (equal " Go " (substring-no-properties (widgetry-button-test--shown widget)))))))

(ert-deftest widgetry-button-hold-draws-a-track ()
  (let ((metrics '(8 16 "monospace" 12 12))
        (paint '("#2F2F2F" "#CBCBCB" "normal")))
    (let ((svg (image-property (widgetry--svg-draw
                                metrics `((" Go " ,paint 0.0 nil (:track 0.5 :track-color "#CD4542"))))
                               :data)))
      (should (string-match-p "fill-opacity=\"0.25\"" svg))
      (should (string-match-p "width=\"16.0\" height=\"2\"" svg)))))

(ert-deftest widgetry-button-status-shows-in-the-tag ()
  (dolist (case '((done "✓" widgetry-button-done-tag widgetry-button-done)
                  (failed "✗" widgetry-button-failed-tag widgetry-button-value)
                  (pending nil widgetry-button-pending-tag widgetry-button-value)))
    (pcase-let ((`(,status ,mark ,tag-face ,face) case))
      (widgetry-button-test--with (list :tag " ● " :value " Run " :status status) count
        (let ((shown (substring-no-properties (widgetry-button-test--shown widget))))
          (should (= (string-width shown) (string-width " ●  Run ")))
          (should (equal (substring shown 1 2)
                         (or mark (widgetry-spinner-frame)))))
        (should (eq (widgetry-button-test--face widget 0) tag-face))
        (should (eq (widgetry-button-test--face widget 4) face))))))

(ert-deftest widgetry-button-status-without-a-tag-adds-no-mark ()
  (widgetry-button-test--with '(:value " Run " :status done) count
    (should (equal " Run " (substring-no-properties (widgetry-button-test--shown widget))))
    (should (eq (widgetry-button-test--face widget 1) 'widgetry-button-done))))

(ert-deftest widgetry-button-done-keeps-its-tint-when-disabled ()
  (widgetry-button-test--with '(:tag " ● " :value " Run " :status done :disabled t) count
    (should (eq (widgetry-button-test--face widget 0) 'widgetry-button-done-tag))
    (should (eq (widgetry-button-test--face widget 4) 'widgetry-button-done))
    (widgetry-button-press)
    (should (= count 0))))

(ert-deftest widgetry-spin-forgets-a-widget-no-longer-pending ()
  (widgetry-button-test--with '(:tag " ● " :value " Run " :status pending) count
    (let ((widgetry--spinning nil) (homun-clock--clients nil))
      (widgetry-spin widget)
      (should (assq 'widgetry-spin homun-clock--clients))
      (should (widgetry--spin-tick))
      (should (memq widget widgetry--spinning))
      (widget-put widget :status 'done)
      (should-not (widgetry--spin-tick))
      (should-not widgetry--spinning))
    (homun-clock--stop)))

;;; widgetry-button-test.el ends here
