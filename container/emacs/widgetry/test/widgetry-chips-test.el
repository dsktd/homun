;;; widgetry-chips-test.el --- Tests for widgetry-chips -*- lexical-binding: t; -*-

(require 'ert)
(require 'widgetry-chips)

(defmacro widgetry-chips-test--with (value seen &rest body)
  "Run BODY with point on a chips widget of VALUE, notified values in SEEN."
  (declare (indent 2))
  `(with-temp-buffer
     (let* ((,seen nil)
            (widget (widget-create 'widgetry-chips :value ,value
                                   :choices '(a bb c)
                                   :notify (lambda (w &rest _) (push (widget-value w) ,seen)))))
       (widget-setup)
       (goto-char (widget-get widget :from))
       (ignore ,seen)
       ,@body)))

(ert-deftest widgetry-chips-toggle-at-point ()
  (widgetry-chips-test--with '(c) seen
    (widgetry-chips-next)
    (widgetry-chips-toggle)
    (should (equal (widget-value widget) '(bb c)))
    (widgetry-chips-toggle)
    (should (equal (widget-value widget) '(c)))
    (should (equal seen '((c) (bb c))))))

(ert-deftest widgetry-chips-value-in-choice-order ()
  (widgetry-chips-test--with '(c) seen
    (widgetry-chips-toggle)
    (should (equal (widget-value widget) '(a c)))))

(ert-deftest widgetry-chips-move-stops-at-ends ()
  (widgetry-chips-test--with nil seen
    (widgetry-chips-previous)
    (widgetry-chips-toggle)
    (should (equal (widget-value widget) '(a)))
    (dotimes (_ 5) (widgetry-chips-next))
    (widgetry-chips-toggle)
    (should (equal (widget-value widget) '(a c)))))

(ert-deftest widgetry-chips-programmatic-set-is-silent ()
  (widgetry-chips-test--with nil seen
    (widget-value-set widget '(a))
    (should-not seen)))

(ert-deftest widgetry-chips-on-chips-are-green ()
  (widgetry-chips-test--with '(bb) seen
    (let ((shown (widgetry-shown widget)))
      (should (eq (get-text-property (+ 3 1) 'face shown) 'widgetry-value))
      (should (eq (get-text-property (+ 3 3 1) 'face shown) 'widgetry-value-on)))))

(ert-deftest widgetry-chips-fixed-width ()
  (widgetry-chips-test--with nil seen
    (let ((w (string-width (widgetry-shown widget))))
      (widget-value-set widget '(a bb c))
      (should (= w (string-width (widgetry-shown widget)))))))

;;; widgetry-chips-test.el ends here

(ert-deftest widgetry-chips-click-picks-chip-by-display-offset ()
  (widgetry-chips-test--with nil seen
    ;; the tag takes 3 cells, then chips " a ", " bb ", " c "
    (set-window-buffer (selected-window) (current-buffer))
    (let* ((pos (marker-position (widget-get widget :from)))
           (event (list 'down-mouse-1
                        (list (selected-window) pos '(0 . 0) 0
                              (cons (widgetry-shown widget) 7)
                              pos '(4 . 0) nil '(4 . 0) '(1 . 1)))))
      (widgetry-chips-toggle event)
      (should (equal (widget-value widget) '(bb))))))

(ert-deftest widgetry-chips-dividers-between-chips ()
  "Every chip but the first starts with a divider; the tag and first chip do not."
  (widgetry-chips-test--with '(a) seen
    (let ((parts (funcall (widget-get widget :parts) widget)))
      (should-not (plist-get (nth 4 (nth 1 parts)) :divider))
      (should (plist-get (nth 4 (nth 2 parts)) :divider))
      (should (plist-get (nth 4 (nth 3 parts)) :divider)))))

(ert-deftest widgetry-chips-single-picks-one-and-shows-labels ()
  (with-temp-buffer
    (let ((widget (widget-create 'widgetry-chips :single t :value '(a)
                                 :choices '(a bb) :labels '((bb . "Big B")))))
      (widget-setup)
      (goto-char (widget-get widget :from))
      (widgetry-chips--toggle widget 1)
      (should (equal (widget-value widget) '(bb)))
      (should (equal (widget-value widget) '(bb)))
      (should (equal (widgetry-chips--label widget 'bb) " Big B "))
      (widgetry-chips--toggle widget 1)
      (should (null (widget-value widget)))
      (widgetry-chips--toggle widget 0)
      (should (equal (widget-value widget) '(a)))
      (widget-put widget :disabled t)
      (widgetry-chips--toggle widget 0)
      (should (equal (widget-value widget) '(a))))))

(ert-deftest widgetry-check-is-one-padded-box ()
  (with-temp-buffer
    (let* ((seen nil)
           (widget (widget-create 'widgetry-check
                                  :notify (lambda (w &rest _) (push (widget-value w) seen)))))
      (widget-setup)
      (should (equal (widgetry-chips--label widget 'on) " ☐  "))
      (goto-char (widget-get widget :from))
      (widgetry-chips-toggle)
      (should (equal (widget-value widget) '(on)))
      (should (equal (widgetry-chips--label widget 'on) " ☑  "))
      (widgetry-chips-toggle)
      (should (equal seen '(nil (on)))))))
